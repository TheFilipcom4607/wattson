import Foundation
import IOKit

/// Whether the machine is being held back, and by what.
///
/// Two sources, deliberately kept apart. macOS publishes a thermal pressure
/// level and nothing else — no temperature, no frequency, no reason — and that
/// level is the only authoritative statement anywhere on the machine that the
/// system is asking for less. What it will not tell you is what that cost, so
/// the second source is the cores' own performance-state residency, which says
/// what they actually ran at against what they can.
///
/// One is the verdict and the other is the evidence. They are not merged into a
/// single number here, because a Mac sitting at a low clock because nothing is
/// asking it to go faster is not throttled, and no arithmetic on frequency alone
/// can tell that apart from a Mac being held down.

// MARK: - What macOS itself says

/// `ProcessInfo`'s thermal pressure, which is the supported API and the whole of
/// it. `pmset -g therm` and `CPU_Speed_Limit` are the Intel-era mechanism and
/// report nothing at all on Apple silicon.
enum ThermalPressure: Int, Comparable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    static func < (a: ThermalPressure, b: ThermalPressure) -> Bool {
        a.rawValue < b.rawValue
    }

    /// Deliberately plain. `fair` is where a busy machine sits much of the time
    /// and is not worth a warning; the two above it are macOS saying it is
    /// actively shedding performance.
    var label: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        }
    }

    /// Whether macOS is asking for less, as opposed to merely running warm.
    var isShedding: Bool { self >= .serious }
}

// MARK: - What the cores actually ran at

/// One cluster's achieved clock against its own ceiling.
struct ClusterSpeed: Identifiable, Equatable {
    /// "Efficiency" or "Performance".
    var name: String
    /// Residency-weighted mean over the sample window, counting only the time
    /// the cluster was awake. Idle time is excluded on purpose: averaging it in
    /// would report a resting machine as though it were being held at 900 MHz.
    var achievedMHz: Double
    /// The top of this machine's own ladder, read from the device tree rather
    /// than a table keyed on model.
    var ceilingMHz: Double
    /// How much of the window the cluster was out of idle at all.
    var busyFraction: Double

    var id: String { name }
    var fractionOfCeiling: Double { ceilingMHz > 0 ? achievedMHz / ceilingMHz : 0 }

    /// Worth showing a figure for. A cluster that was awake for a rounding
    /// error of the window has an average that means nothing.
    var isMeaningful: Bool { busyFraction > 0.05 }
}

/// How much the machine is being held back, in one word.
enum ThrottleLevel: Int, Comparable {
    case none
    case slight
    case moderate
    case heavy

    static func < (a: ThrottleLevel, b: ThrottleLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .none: return "No"
        case .slight: return "Slightly"
        case .moderate: return "Yes"
        case .heavy: return "A lot"
        }
    }
}

/// Everything the panel needs to talk about being held back.
struct ThrottleSnapshot: Equatable {
    var pressure: ThermalPressure = .nominal
    var clusters: [ClusterSpeed] = []

    /// The cluster worth quoting: the performance one when it did anything,
    /// since that is the one whose ceiling people mean.
    var headline: ClusterSpeed? {
        clusters.first { $0.name.hasPrefix("Performance") && $0.isMeaningful }
            ?? clusters.first { $0.isMeaningful }
    }

    /// The one-word answer, taken as the worse of the two things that can be
    /// known — because either one alone is wrong on its own.
    ///
    /// macOS's own level misses real throttling outright: cores measured here
    /// boosting to 4464 MHz and being pulled back to 3779 within six seconds
    /// had `thermalState` reading nominal the whole way down. And frequency
    /// alone cannot tell a machine being held under its ceiling from one that
    /// simply has nothing to do. Each covers the other's blind spot, so the
    /// answer is whichever is worse.
    var level: ThrottleLevel { max(thermalLevel, speedLevel) }

    private var thermalLevel: ThrottleLevel {
        switch pressure {
        case .nominal: return .none
        case .fair: return .slight
        case .serious: return .moderate
        case .critical: return .heavy
        }
    }

    /// What the shortfall from the ceiling says, and only when the cores were
    /// genuinely being asked to work. Below that the figure means nothing: a
    /// resting Mac sits far under its ceiling by choice, and calling that
    /// throttling would make the row cry wolf all day.
    private var speedLevel: ThrottleLevel {
        guard let cluster = headline, cluster.busyFraction > 0.4 else { return .none }
        switch cluster.fractionOfCeiling {
        case 0.95...: return .none
        case 0.85..<0.95: return .slight
        case 0.70..<0.85: return .moderate
        default: return .heavy
        }
    }
}

// MARK: - Reading the performance states

/// A live reader for CPU performance-state residency, over IOReport.
///
/// IOReport is not public API. There is no header for it; the functions are
/// resolved out of `libIOReport.dylib` by name, and every one of them is
/// optional — if any is missing, or the channels are not shaped the way this
/// expects, the whole reader reports nothing and the panel shows nothing. That
/// is the point: a private interface that changes under us must make the
/// feature disappear, never make it lie.
///
/// It needs no privileges. Subscribing and sampling both work as an ordinary
/// user, which is what makes this worth doing at all — `powermetrics`, the
/// documented way to the same numbers, needs root.
final class CPUSpeedReader {
    private var subscription: AnyObject?
    private var subscribedChannels: CFMutableDictionary?
    /// Residencies are cumulative since boot, so a single sample says nothing
    /// about now. Every reading is the difference between two.
    private var previousSample: CFDictionary?

    private let efficiencyLadder: [Double]
    private let performanceLadder: [Double]

    /// Nil on any machine this cannot read, which the caller treats as "no such
    /// feature" rather than as an error worth reporting.
    init?() {
        guard IOReport.isAvailable else { return nil }
        efficiencyLadder = Self.ladder(forKey: "voltage-states1-sram")
        performanceLadder = Self.ladder(forKey: "voltage-states5-sram")
        guard !efficiencyLadder.isEmpty, !performanceLadder.isEmpty else { return nil }
    }

    /// Whether this machine can report performance states at all.
    ///
    /// Resolved once, by building a reader and throwing it away: the initialiser
    /// only opens a library and reads the device tree, and does not subscribe to
    /// anything. Asked by the panel so it can leave the section out entirely
    /// rather than show a row that will never fill in.
    static let isSupported: Bool = { CPUSpeedReader() != nil }()

    deinit { stop() }

    /// Drops the subscription. Sampling stops costing anything the moment
    /// nobody is looking at the panel.
    func stop() {
        subscription = nil
        subscribedChannels = nil
        previousSample = nil
    }

    /// One window's worth of residency, or nil until there are two samples to
    /// subtract. Call it on whatever cadence the panel is refreshing at; the
    /// window is simply the time since the last call.
    func read() -> [ClusterSpeed]? {
        guard let sample = takeSample() else { return nil }
        defer { previousSample = sample }
        guard let previous = previousSample,
              let delta = IOReport.delta(previous, sample)
        else { return nil }
        return clusters(from: delta)
    }

    // MARK: - Sampling

    private func takeSample() -> CFDictionary? {
        if subscription == nil { subscribe() }
        guard let subscription, let subscribedChannels else { return nil }
        return IOReport.samples(subscription, subscribedChannels)
    }

    private func subscribe() {
        guard let channels = IOReport.channels(
            group: "CPU Stats", subgroup: "CPU Core Performance States"
        ) else { return }
        guard let (subscription, subscribed) = IOReport.subscribe(to: channels) else { return }
        self.subscription = subscription
        self.subscribedChannels = subscribed
    }

    // MARK: - Turning residency into a frequency

    private func clusters(from delta: CFDictionary) -> [ClusterSpeed]? {
        var busy: [String: Double] = [:]
        var idle: [String: Double] = [:]
        /// Residency-weighted frequency, summed before it is divided.
        var weighted: [String: Double] = [:]
        var ceiling: [String: Double] = [:]

        for channel in IOReport.channels(in: delta) {
            guard let name = IOReport.channelName(channel) else { continue }
            // ECPU0, ECPU1, ... and PCPU0, PCPU1, ...
            let isEfficiency = name.hasPrefix("E")
            guard isEfficiency || name.hasPrefix("P") else { continue }
            let ladder = isEfficiency ? efficiencyLadder : performanceLadder
            let cluster = isEfficiency ? "Efficiency" : "Performance"

            let states = IOReport.stateCount(channel)
            // The first state is idle and the rest are the ladder, in order.
            // Mapping by position rather than by parsing the state names, which
            // are an undocumented `V<n>P<m>` and would silently mis-map the
            // moment that changed. If the shapes disagree there is nothing
            // trustworthy to report, so report nothing.
            guard states == Int32(ladder.count) + 1 else { return nil }

            for index in 0..<states {
                let residency = Double(IOReport.residency(channel, index))
                guard residency > 0 else { continue }
                if index == 0 {
                    idle[cluster, default: 0] += residency
                } else {
                    busy[cluster, default: 0] += residency
                    weighted[cluster, default: 0] += residency * ladder[Int(index) - 1]
                }
            }
            ceiling[cluster] = ladder.last ?? 0
        }

        guard !busy.isEmpty || !idle.isEmpty else { return nil }

        return ["Performance", "Efficiency"].compactMap { cluster -> ClusterSpeed? in
            guard let top = ceiling[cluster] else { return nil }
            let active = busy[cluster] ?? 0
            let resting = idle[cluster] ?? 0
            let window = active + resting
            guard window > 0 else { return nil }
            return ClusterSpeed(
                name: cluster,
                achievedMHz: active > 0 ? (weighted[cluster] ?? 0) / active : 0,
                ceilingMHz: top,
                busyFraction: active / window
            )
        }
    }

    // MARK: - The machine's own frequency ladder

    /// The available clocks for one cluster, in MHz, ascending.
    ///
    /// From the device tree rather than a table of Apple's published figures,
    /// so it is right on machines that did not exist when this was written.
    /// The property is pairs of 32-bit (frequency in kHz, voltage); only the
    /// first half of each pair is wanted here.
    private static func ladder(forKey key: String) -> [Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let data = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Data, data.count >= 8 else { continue }

            var steps: [Double] = []
            data.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: data.count - 7, by: 8) {
                    let kilohertz = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    if kilohertz > 0 { steps.append(Double(kilohertz) / 1000) }
                }
            }
            if !steps.isEmpty { return steps }
        }
        return []
    }
}

// MARK: - The private interface, kept behind one wall

/// Every call into `libIOReport.dylib`, resolved by name and every one of them
/// optional.
///
/// Confined to this one type so that the rest of the app never touches a symbol
/// it cannot see the declaration of, and so there is exactly one place to look
/// when a future macOS changes something.
private enum IOReport {
    private typealias CopyChannelsInGroup = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c)
        (UnsafeRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?)
        -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c)
        (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private struct Symbols {
        let copyChannelsInGroup: CopyChannelsInGroup
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let createSamplesDelta: CreateSamplesDelta
        let channelGetName: ChannelGetName
        let stateGetCount: StateGetCount
        let stateGetResidency: StateGetResidency
    }

    /// Resolved once. A missing symbol leaves this nil for the life of the run,
    /// and every entry point below then does nothing.
    private static let symbols: Symbols? = {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func find(_ name: String) -> UnsafeMutableRawPointer? { dlsym(library, name) }
        guard let group = find("IOReportCopyChannelsInGroup"),
              let subscribe = find("IOReportCreateSubscription"),
              let samples = find("IOReportCreateSamples"),
              let delta = find("IOReportCreateSamplesDelta"),
              let name = find("IOReportChannelGetChannelName"),
              let count = find("IOReportStateGetCount"),
              let residency = find("IOReportStateGetResidency")
        else { return nil }
        return Symbols(
            copyChannelsInGroup: unsafeBitCast(group, to: CopyChannelsInGroup.self),
            createSubscription: unsafeBitCast(subscribe, to: CreateSubscription.self),
            createSamples: unsafeBitCast(samples, to: CreateSamples.self),
            createSamplesDelta: unsafeBitCast(delta, to: CreateSamplesDelta.self),
            channelGetName: unsafeBitCast(name, to: ChannelGetName.self),
            stateGetCount: unsafeBitCast(count, to: StateGetCount.self),
            stateGetResidency: unsafeBitCast(residency, to: StateGetResidency.self)
        )
    }()

    static var isAvailable: Bool { symbols != nil }

    static func channels(group: String, subgroup: String) -> CFMutableDictionary? {
        guard let symbols else { return nil }
        return symbols.copyChannelsInGroup(
            group as CFString, subgroup as CFString, 0, 0, 0
        )?.takeRetainedValue()
    }

    static func subscribe(
        to channels: CFMutableDictionary
    ) -> (subscription: AnyObject, channels: CFMutableDictionary)? {
        guard let symbols else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = symbols
            .createSubscription(nil, channels, &subscribed, 0, nil)?.takeRetainedValue(),
              let resolved = subscribed?.takeRetainedValue()
        else { return nil }
        return (subscription, resolved)
    }

    static func samples(_ subscription: AnyObject, _ channels: CFMutableDictionary) -> CFDictionary? {
        guard let symbols else { return nil }
        return symbols.createSamples(subscription, channels, nil)?.takeRetainedValue()
    }

    static func delta(_ previous: CFDictionary, _ current: CFDictionary) -> CFDictionary? {
        guard let symbols else { return nil }
        return symbols.createSamplesDelta(previous, current, nil)?.takeRetainedValue()
    }

    /// The channel list out of a sample, kept as CoreFoundation throughout.
    ///
    /// Bridging these to Swift dictionaries and handing them back is what the
    /// first attempt at this did, and `IOReportChannelGetChannelName` rejects
    /// the result: the functions want the CFDictionary they handed out, not a
    /// Swift value that merely prints the same.
    static func channels(in sample: CFDictionary) -> [CFDictionary] {
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let raw = CFDictionaryGetValue(sample, key) else { return [] }
        let array = unsafeBitCast(raw, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: CFDictionary.self)
        }
    }

    static func channelName(_ channel: CFDictionary) -> String? {
        guard let symbols else { return nil }
        return symbols.channelGetName(channel)?.takeRetainedValue() as String?
    }

    static func stateCount(_ channel: CFDictionary) -> Int32 {
        symbols?.stateGetCount(channel) ?? 0
    }

    static func residency(_ channel: CFDictionary, _ index: Int32) -> Int64 {
        symbols?.stateGetResidency(channel, index) ?? 0
    }
}
