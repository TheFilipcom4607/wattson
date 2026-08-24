import AppKit
import Foundation
import ServiceManagement
import SwiftUI

enum TitleMode: String, CaseIterable, Identifiable {
    case livePower
    case batteryFlow
    case batteryLevel
    case batteryLevelFlow
    case batteryLevelPower
    case deviceCount
    case fastestLink
    case adapterRating
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .livePower: return "Live wattage"
        case .batteryFlow: return "Battery flow"
        case .batteryLevel: return "Battery level"
        case .batteryLevelFlow: return "Level and flow"
        case .batteryLevelPower: return "Level and wattage"
        case .deviceCount: return "Device count"
        case .fastestLink: return "Fastest link"
        case .adapterRating: return "Charger rating"
        case .iconOnly: return "Icon only"
        }
    }
}

/// What sits to the left of the title in the menu bar.
enum MenuBarIcon: Equatable {
    /// The battery, filled to the level it is actually at.
    case battery(percent: Int, charging: Bool, lowPower: Bool)
    case symbol(String)
}

@MainActor
final class DeviceModel: ObservableObject {
    @Published private(set) var result = ScanResult()
    @Published private(set) var power = PowerSnapshot()
    @Published private(set) var ports: [PortInfo] = []
    /// Rolling history for the sparkline, oldest first.
    @Published private(set) var history: [PowerSample] = []
    /// Mounted volumes, mapped to the USB devices they live on.
    @Published private(set) var volumes: [VolumeInfo] = []
    /// Eject failures, kept next to the button that caused them.
    @Published private(set) var ejectErrors: [String: String] = [:]
    @Published private(set) var ejecting: Set<String> = []

    /// What was attached and when, for as long as this app was running.
    let log = ConnectionLog()

    private static let historyLimit = 150
    @Published private(set) var isScanning = false
    @Published private(set) var launchAtLogin = false

    /// Set while the popover is open, so power sampling can speed up.
    @Published var isPresented = false {
        didSet {
            restartPowerTimer()
            // Reading it costs a subprocess, so it is read when somebody is
            // about to look at it rather than on the timer.
            if isPresented { refreshLowPower() }
            // Performance states are only worth subscribing to while somebody
            // is reading them, and the reader is nothing but a subscription and
            // one previous sample, so it costs nothing to build again.
            if isPresented {
                speedReader = CPUSpeedReader()
            } else {
                speedReader = nil
                throttle.clusters = []
            }
        }
    }

    // MARK: - Being held back

    /// Thermal pressure, and what the cores actually ran at.
    @Published private(set) var throttle = ThrottleSnapshot()
    /// Nil while the panel is closed, and on any machine whose performance
    /// states cannot be read.
    private var speedReader: CPUSpeedReader?

    /// Whether this Mac can report performance states at all, so the panel can
    /// leave the whole section out rather than show an empty one. A fact about
    /// the machine, not about whether sampling happens to be running.
    var canReadSpeed: Bool { CPUSpeedReader.isSupported }

    /// Why the cores are below their ceiling, when that can be said honestly.
    ///
    /// Only ever names a cause it has evidence for. Cores sitting low because
    /// nothing is asking them to go faster are not throttled, so this says
    /// nothing at all unless they are busy and still short of the ceiling — and
    /// even then it stays quiet unless one of the three things Wattson can
    /// actually see is true. Guessing "probably heat" is what every other tool
    /// does and is wrong as often as not.
    var throttleReason: String? {
        guard let cluster = throttle.headline,
              cluster.busyFraction > 0.4,
              cluster.fractionOfCeiling < 0.9
        else { return nil }

        if isLowPowerOn { return "Held back by Low Power Mode" }
        if throttle.pressure.isShedding { return "Held back by heat" }
        // The charger being unable to keep up shows as the battery going down
        // while plugged in — the same measured fact the drain notice is built
        // on, not a comparison against what a bigger brick could have done.
        if power.externalConnected, let watts = power.batteryWatts, watts < -1 {
            return "The charger is not keeping up"
        }
        return nil
    }

    // MARK: - Low Power Mode

    @Published private(set) var lowPower = LowPowerMode.State()
    /// Set while the authorisation dialog is up or pmset is running.
    @Published private(set) var lowPowerBusy = false
    @Published var lowPowerError: String?
    /// Whether the switch can work without a password. Nil until asked.
    @Published private(set) var lowPowerPromptless: Bool?

    func refreshLowPower() {
        Task.detached(priority: .userInitiated) {
            let state = LowPowerMode.read()
            let promptless = state.isSupported ? LowPowerMode.isPromptless : false
            await MainActor.run {
                self.lowPower = state
                self.lowPowerPromptless = promptless
            }
        }
    }

    /// Turns Low Power Mode on or off for both power sources.
    ///
    /// `setUp` runs first when the rule is not in place — the caller has
    /// explained what is about to be installed and been told to go ahead.
    func setLowPower(_ on: Bool, installingIfNeeded setUp: Bool) {
        guard !lowPowerBusy else { return }
        lowPowerBusy = true
        lowPowerError = nil
        Task.detached(priority: .userInitiated) {
            let failure: String?
            var needsSetup = false
            do {
                if setUp { try LowPowerMode.installPromptless() }
                try LowPowerMode.set(on)
                failure = nil
            } catch LowPowerMode.Failure.cancelled {
                // Closing the dialog is an answer. Nothing to report.
                failure = nil
            } catch LowPowerMode.Failure.needsSetup {
                // The rule is not doing its job whatever the file system says,
                // so the next flip of the switch offers to put it right.
                needsSetup = true
                failure = LowPowerMode.Failure.needsSetup.localizedDescription
            } catch {
                failure = error.localizedDescription
            }
            let state = LowPowerMode.read()
            let promptless = needsSetup ? false : LowPowerMode.isPromptless
            await MainActor.run {
                self.lowPower = state
                self.lowPowerPromptless = promptless
                self.lowPowerError = failure
                self.lowPowerBusy = false
            }
        }
    }

    /// Hands the rule back, for Settings to show and for the alert to quote.
    var lowPowerRule: String { LowPowerMode.rule() }

    func removeLowPowerRule() {
        guard !lowPowerBusy else { return }
        lowPowerBusy = true
        lowPowerError = nil
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try LowPowerMode.removePromptless()
                failure = nil
            } catch LowPowerMode.Failure.cancelled {
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            let promptless = LowPowerMode.isPromptless
            await MainActor.run {
                self.lowPowerPromptless = promptless
                self.lowPowerError = failure
                self.lowPowerBusy = false
            }
        }
    }

    @Published var titleMode: TitleMode {
        didSet { UserDefaults.standard.set(titleMode.rawValue, forKey: Self.titleModeKey) }
    }

    // Which sections of the panel are shown.
    @Published var showSparkline: Bool { didSet { save(showSparkline, "showSparkline") } }
    @Published var showCable: Bool { didSet { save(showCable, "showCable") } }
    @Published var showPortLimits: Bool { didSet { save(showPortLimits, "showPortLimits") } }
    @Published var showThrottle: Bool { didSet { save(showThrottle, "showThrottle") } }
    @Published var showDevices: Bool { didSet { save(showDevices, "showDevices") } }
    @Published var showVendors: Bool { didSet { save(showVendors, "showVendors") } }
    /// Diagnostic capture is deliberately opt-in: its reports can be large and
    /// may contain serial numbers and other hardware identifiers.
    @Published var showDebugOptions: Bool { didSet { save(showDebugOptions, "showDebugOptions") } }
    // Which changes are worth saying out loud, and where. All off unless asked
    // for: an app that starts talking after an update is an app people quit.
    @Published var announcePower: Bool { didSet { save(announcePower, "announcePower") } }
    @Published var announceStorage: Bool { didSet { save(announceStorage, "announceStorage") } }
    @Published var announceDevices: Bool { didSet { save(announceDevices, "announceDevices") } }
    /// Only ever fires on a battery that is genuinely going down while plugged
    /// in — never on the charger merely being smaller than the Mac could use.
    @Published var warnBatteryDrain: Bool { didSet { save(warnBatteryDrain, "warnBatteryDrain") } }
    /// Liquid in a port. Defaults on: it is a hardware finding about damage in
    /// progress, not an announcement about something being plugged in.
    @Published var warnLiquid: Bool { didSet { save(warnLiquid, "warnLiquid") } }
    @Published var announceContract: Bool { didSet { save(announceContract, "announceContract") } }
    @Published var noticesInPanel: Bool {
        didSet { save(noticesInPanel, "noticesInPanel"); applyNoticeDelivery() }
    }
    @Published var noticesInCenter: Bool {
        didSet { save(noticesInCenter, "noticesInCenter"); applyNoticeDelivery() }
    }

    private static let titleModeKey = "titleMode"

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Defaults to true when the key has never been written.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// A notice switch that has never been set inherits `announceChanges`, the
    /// single on/off these grew out of, so anyone who had announcements on
    /// keeps them rather than having them silently turned off by an update.
    private static func noticeFlag(_ key: String, default fallback: Bool? = nil) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key) as? Bool { return stored }
        return fallback ?? UserDefaults.standard.bool(forKey: "announceChanges")
    }
    private var watcher: HotplugWatcher?
    private var powerWatcher: PowerSourceWatcher?
    private var pendingRescan: Task<Void, Never>?
    private var powerTimer: Timer?
    private var lowPowerTimer: Timer?
    private let volumeMonitor = VolumeMonitor()
    private var volumeObservers: [NSObjectProtocol] = []

    /// The first scan of a run is a baseline, not a burst of arrivals.
    private var hasScanned = false
    private let notices = NoticeCenter()
    private var toastTask: Task<Void, Never>?
    private var pendingArrivals: [DeviceNode] = []
    private var pendingDepartures: [DeviceNode] = []
    private var shownArrivals: [DeviceNode] = []
    private var shownDepartures: [DeviceNode] = []
    /// The notice currently on screen, and the storage device it is still
    /// waiting on the volume for.
    private var openNotice: Notice?
    private var awaitingVolume: DeviceNode?
    private var volumeWait: Task<Void, Never>?

    // What the last sample said, so this one can be compared against it.
    private var lastPower: PowerSnapshot?
    /// When the battery started going down on a charger, and whether that has
    /// already been said. One notice per stretch of draining, not one a second.
    private var drainingSince: Date?
    private var drainAnnounced = false
    /// Ports already announced as wet, so a standing condition is not
    /// re-announced every tick. A port dropping out of the set is what re-arms
    /// it once the connector has dried.
    private var liquidAnnounced: Set<String> = []

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.titleModeKey) ?? ""
        titleMode = TitleMode(rawValue: stored) ?? .livePower
        showSparkline = Self.flag("showSparkline")
        showCable = Self.flag("showCable")
        showPortLimits = Self.flag("showPortLimits")
        showThrottle = Self.flag("showThrottle")
        showDevices = Self.flag("showDevices")
        showVendors = Self.flag("showVendors")
        showDebugOptions = UserDefaults.standard.bool(forKey: "showDebugOptions")
        announcePower = Self.noticeFlag("announcePower")
        announceStorage = Self.noticeFlag("announceStorage")
        announceDevices = Self.noticeFlag("announceDevices")
        warnBatteryDrain = Self.noticeFlag("warnBatteryDrain", default: true)
        warnLiquid = Self.noticeFlag("warnLiquid", default: true)
        announceContract = Self.noticeFlag("announceContract", default: true)
        noticesInPanel = Self.noticeFlag("noticesInPanel", default: true)
        noticesInCenter = Self.noticeFlag("noticesInCenter", default: false)

        watcher = HotplugWatcher { [weak self] in
            self?.scheduleRescan()
        }
        watcher?.start()

        // Plug and unplug should register immediately, not on the next tick.
        powerWatcher = PowerSourceWatcher { [weak self] in
            Task { @MainActor in
                self?.refresh()
                // The setting is kept per power source, so which one is in
                // force just changed.
                self?.refreshLowPower()
            }
        }
        powerWatcher?.start()

        // Low Power Mode can equally be switched from Control Center or System
        // Settings, and the icon has to follow it there. One subprocess every
        // half minute is cheap enough to keep the colour honest.
        lowPowerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLowPower() }
        }

        // Mounting is its own event: an encrypted volume can be unlocked long
        // after the drive it lives on was plugged in, and no USB event fires.
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.readVolumes() }
            }
            volumeObservers.append(observer)
        }

        applyNoticeDelivery()
        // The user can withdraw Notification Center's permission in System
        // Settings without the app hearing about it, so ask at every launch.
        notices.refreshAuthorization()

        refreshLaunchAtLogin()
        refreshLowPower()
        refresh()
        restartPowerTimer()
    }

    deinit {
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    var titleText: String? { title(for: titleMode) }

    /// Broken out from `titleText` so Settings can preview every mode live.
    func title(for mode: TitleMode) -> String? {
        switch mode {
        case .iconOnly:
            return nil

        case .livePower:
            guard let watts = livePowerWatts else { return "—" }
            return format(watts)

        case .batteryFlow:
            // Always signed: -10.27 W draining, +10.27 W charging. A resting
            // battery would otherwise land on "-0.00 W".
            guard let watts = power.batteryWatts else { return "—" }
            if abs(watts) < 0.005 { return "0.00 W" }
            return String(format: "%+.2f W", watts)

        case .batteryLevel:
            guard let percent = power.batteryPercent else { return "—" }
            return "\(percent)%"

        case .batteryLevelFlow:
            // Both halves of the question at once: how full, and which way it
            // is going. One decimal rather than the two everywhere else — this
            // is the widest thing Wattson can put in a menu bar, and the second
            // decimal of a battery flow changes several times a second anyway.
            guard let percent = power.batteryPercent else { return "—" }
            guard let watts = power.batteryWatts else { return "\(percent)%" }
            let flow = abs(watts) < 0.05 ? "0.0 W" : String(format: "%+.1f W", watts)
            return "\(percent)% \(flow)"

        case .batteryLevelPower:
            // The same pairing, but the wattage is whichever one you would
            // actually want: on a charger, what is arriving from the wall —
            // charge going into the cell is the least of what that power is
            // doing. On battery there is only one figure, so it is that one.
            guard let percent = power.batteryPercent else { return title(for: .livePower) }
            guard let watts = livePowerWatts else { return "\(percent)%" }
            return "\(percent)% " + String(format: "%.1f W", watts)

        case .deviceCount:
            let count = result.deviceCount
            return count == 1 ? "1 Device" : "\(count) Devices"

        case .fastestLink:
            guard let mbps = result.fastestMbps, mbps > 0 else { return "—" }
            return SpeedFormat.humanRate(mbps)

        case .adapterRating:
            guard let watts = power.adapterWatts else { return "No Power" }
            return String(format: "%.0f W", watts)
        }
    }

    /// Match the panel exactly: if it reads 2.34 W, so does the menu bar.
    private func format(_ watts: Double) -> String {
        String(format: "%.2f W", watts)
    }

    /// The one live figure: what is coming from the wall while plugged in, and
    /// what is leaving the cell when not — which reads negative, as it should.
    private var livePowerWatts: Double? {
        if power.externalConnected, let watts = power.inputWatts { return watts }
        return power.batteryWatts
    }

    /// Power going into the cell, which is what the bolt in the icon means.
    /// The registry's own flag lags a plug or unplug by a tick, so the measured
    /// flow decides wherever there is one.
    var isCharging: Bool {
        if let watts = power.batteryWatts, abs(watts) > 0.05 { return watts > 0 }
        return power.isCharging
    }

    /// Every power mode gets the real battery, drawn to its actual level, so
    /// the item can stand in for the system's own battery in the menu bar. The
    /// two modes that are about what is plugged in rather than about power keep
    /// their connector.
    var menuBarIcon: MenuBarIcon {
        switch titleMode {
        case .deviceCount, .fastestLink:
            return .symbol("cable.connector")
        case .adapterRating where power.externalConnected:
            return .symbol("powerplug.fill")
        default:
            guard let percent = power.batteryPercent else {
                // A Mac with no battery to draw.
                return .symbol(power.externalConnected ? "powerplug.fill" : "bolt.slash")
            }
            return .battery(percent: percent, charging: isCharging, lowPower: isLowPowerOn)
        }
    }

    /// Low Power Mode as it applies right now, which is what the icon colours
    /// itself for.
    var isLowPowerOn: Bool {
        lowPower.inEffect(externalConnected: power.externalConnected)
    }

    // MARK: - Sampling

    func refresh() {
        readPower()
        guard !isScanning else { return }
        isScanning = true
        Task {
            let scan = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
            let before = self.presentDevices
            self.result = scan
            self.attributeMeasuredPower()
            self.noteChanges(from: before)
            self.readVolumes()
            self.isScanning = false
        }
    }

    // MARK: - What changed

    /// Everything on the tree right now, keyed by the identity history uses.
    private var presentDevices: [String: DeviceNode] {
        var devices: [String: DeviceNode] = [:]
        for row in result.devices.flatMap({ $0.flattenedRows() }) {
            devices[row.node.persistentKey] = row.node
        }
        return devices
    }

    /// The log and the toast are the same fact told twice, and both fall out of
    /// diffing consecutive scans — `HotplugWatcher` only ever says "something
    /// changed", never what.
    private func noteChanges(from before: [String: DeviceNode]) {
        let after = presentDevices
        // The first scan of a run is the baseline. Everything already attached
        // at launch would otherwise read as having just arrived, and the log is
        // explicit that it covers only what happened while Wattson watched.
        guard hasScanned else {
            hasScanned = true
            return
        }

        let arrived = after.filter { before[$0.key] == nil }.map(\.value)
        let left = before.filter { after[$0.key] == nil }.map(\.value)
        guard !arrived.isEmpty || !left.isEmpty else { return }

        let now = Date()
        log.append(
            arrived.map {
                ConnectionEvent(device: $0.persistentKey, name: $0.name, kind: .connected, at: now)
            } + left.map {
                ConnectionEvent(device: $0.persistentKey, name: $0.name, kind: .disconnected, at: now)
            }
        )

        // Nothing to announce to somebody already looking at the list.
        guard !isPresented else { return }
        // Filtered before they are summarised, not after: with storage on and
        // devices off, a hub carrying one flash drive should say "flash drive",
        // not "hub, 4 devices" with the drive buried in the count.
        pendingArrivals += arrived.filter(announces)
        pendingDepartures += left.filter(announces)
        guard !pendingArrivals.isEmpty || !pendingDepartures.isEmpty else { return }
        scheduleToast()
    }

    /// Whether this device's comings and goings are switched on.
    private func announces(_ node: DeviceNode) -> Bool {
        node.isStorage ? announceStorage : announceDevices
    }

    /// A hub announces its downstream devices in a burst, which would put one
    /// toast per device on screen. The debounce collapses the burst; merging
    /// into a toast that is still up collapses the second rescan into the first.
    private func scheduleToast() {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.presentToast()
        }
    }

    private func presentToast() {
        // Merging into a notice that is still up keeps its id, so the second
        // rescan of one plug-in updates the first notice rather than posting a
        // second banner beside it.
        var id = "devices.\(Date().timeIntervalSince1970)"
        if let open = openNotice, open.category != .power {
            pendingArrivals = unique(shownArrivals + pendingArrivals)
            pendingDepartures = unique(shownDepartures + pendingDepartures)
            id = open.id
        }
        guard let notice = NoticeBuilder.devices(
            arrived: pendingArrivals,
            left: pendingDepartures,
            id: id,
            volumes: { [weak self] in self?.volumes(for: $0) ?? [] }
        ) else { return }

        shownArrivals = pendingArrivals
        shownDepartures = pendingDepartures
        pendingArrivals = []
        pendingDepartures = []

        // A drive is announced the moment it is on the bus, and told again in
        // place once its volume mounts and its size is known.
        awaitingVolume = notice.isPending ? shownArrivals.first : nil
        post(notice)
        scheduleVolumeGiveUp(for: notice)
    }

    /// A disk that never mounts — locked, unformatted, or simply slow — must
    /// not leave a notice reading "reading volume…" for good, least of all in
    /// Notification Center where it would sit in the history saying it.
    private func scheduleVolumeGiveUp(for notice: Notice) {
        volumeWait?.cancel()
        guard notice.isPending else { return }
        volumeWait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, var open = self.openNotice,
                  open.id == notice.id, open.isPending
            else { return }
            self.awaitingVolume = nil
            open.isPending = false
            open.detail = open.detail?
                .replacingOccurrences(of: " · reading volume…", with: "")
                .nilIfEmpty
            self.post(open)
        }
    }

    /// The volume behind a notice that is waiting for one has mounted.
    private func fillInVolume() {
        guard let node = awaitingVolume, let open = openNotice, open.isPending,
              !volumes(for: node).isEmpty
        else { return }
        awaitingVolume = nil
        volumeWait?.cancel()
        guard let filled = NoticeBuilder.devices(
            arrived: shownArrivals, left: shownDepartures, id: open.id,
            volumes: { [weak self] in self?.volumes(for: $0) ?? [] }
        ) else { return }
        post(filled)
    }

    /// One way in for every notice, so the open one is always known.
    private func post(_ notice: Notice) {
        openNotice = notice
        notices.post(notice)
    }

    private func applyNoticeDelivery() {
        notices.delivery = NoticeDelivery(
            panel: noticesInPanel, notificationCenter: noticesInCenter
        )
    }

    /// Turning Notification Center on is what asks for permission — never at
    /// launch, when the app has nothing to say yet. Hands back whether it will
    /// actually deliver, so the switch can go back if it will not.
    func enableNotificationCenter(_ completion: @escaping (Bool) -> Void) {
        notices.authorizeNotificationCenter { granted in
            if !granted { self.noticesInCenter = false }
            // Proof the pipe works, sent down the pipe. Notification Center can
            // be authorised and still deliver nothing — a Focus, a Do Not
            // Disturb schedule — and a switch that silently does nothing is
            // worse than one that says so.
            if granted {
                self.post(Notice(
                    id: "notices.enabled",
                    category: .power,
                    symbol: "bell.badge.fill",
                    title: "Notifications are on",
                    detail: "This is what Wattson's notices will look like."
                ))
            }
            completion(granted)
        }
    }

    private func unique(_ nodes: [DeviceNode]) -> [DeviceNode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert($0.persistentKey).inserted }
    }

    // MARK: - Volumes

    private func readVolumes() {
        volumes = volumeMonitor.read()
        fillInVolume()
    }

    func volumes(for node: DeviceNode) -> [VolumeInfo] {
        volumes.filter { $0.deviceID == node.id }
    }

    func reveal(_ volume: VolumeInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([volume.url])
    }

    func eject(_ volume: VolumeInfo) {
        ejectErrors[volume.id] = nil
        ejecting.insert(volume.id)
        volumeMonitor.eject(volume) { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.ejecting.remove(volume.id)
                self.ejectErrors[volume.id] = message
                self.readVolumes()
                // A successful eject takes the device off the bus, which the
                // tree should show without waiting for the hotplug rescan.
                if message == nil { self.refresh() }
            }
        }
    }

    /// Cheap: IORegistry reads, so they can run often while the panel is open.
    /// Port state has to be polled — attaching a charger fires no USB event.
    private func readPower() {
        power = PowerMonitor.read()
        ports = PortMonitor.read()

        // Accessory draw is the sum of what the USB-C rails actually deliver,
        // rather than every rail the SMC exposes.
        let accessories = ports
            .filter { $0.kind == .usbC }
            .compactMap(\.outputWatts)
            .reduce(0, +)
        power.accessoryWatts = accessories > 0.05 ? accessories : nil

        // Which port the charger is on, for the charger row.
        let source = ports.first { $0.isConnected && $0.negotiated != nil }
        power.sourcePortName = source?.name

        // Rail voltage from the registry lags 10-30 s, so a charger swap could
        // leave it reading 20 V on a 5 V source and inflate the derived amps.
        // The negotiated contract is current, so trust it when the two disagree.
        if let contract = source?.negotiated?.volts, contract > 1 {
            let stale = power.inputVolts.map { abs($0 - contract) / contract > 0.25 } ?? true
            if stale {
                power.inputVolts = contract
                power.inputAmps = power.inputWatts.map { $0 / contract }
            }
        }

        // Port wattage moves every second, so re-attribute on each sample.
        attributeMeasuredPower()

        // Thermal pressure is a property read with no I/O behind it, so it is
        // taken every tick whether or not anybody is looking. The performance
        // states are a subscription and only run while the panel is open; the
        // first reading after opening is nil, because a residency figure is the
        // difference between two samples and there is only one so far.
        throttle.pressure = ThermalPressure(ProcessInfo.processInfo.thermalState)
        if let clusters = speedReader?.read() {
            throttle.clusters = clusters
        }

        // Track whatever the headline shows: input from the wall, or system draw.
        let watts = power.externalConnected
            ? power.inputWatts
            : power.systemLoadWatts
        if let watts {
            history.append(PowerSample(watts: watts, charging: power.externalConnected))
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
        }

        notePowerChanges()
    }

    // MARK: - What the power did

    /// Charger events, which no notification used to cover at all: nothing on
    /// the bus changes when a charger is plugged in, so the device diff never
    /// saw one.
    private func notePowerChanges() {
        defer { lastPower = power }
        // The first sample of a run is the baseline. Whatever was already
        // plugged in at launch did not just happen.
        guard let previous = lastPower else { return }
        guard announcePower, !isPresented else { return }

        if power.externalConnected, !previous.externalConnected {
            drainingSince = nil
            drainAnnounced = false
            post(NoticeBuilder.adapterAttached(power, settled: adapterHasSettled))
            return
        }

        if !power.externalConnected, previous.externalConnected {
            drainingSince = nil
            drainAnnounced = false
            post(NoticeBuilder.adapterRemoved(power))
            return
        }

        guard power.externalConnected else { return }

        // The contract lands a moment after the plug does. Fill the notice that
        // said "negotiating…" in place, rather than posting a second one.
        if let open = openNotice, open.id == NoticeBuilder.adapterNoticeID, open.isPending {
            if adapterHasSettled {
                post(NoticeBuilder.adapterAttached(power, settled: true))
            }
            return
        }

        noteContractChange(from: previous)
        noteDrainOnCharger()
        noteLiquid()
    }

    /// Whether there is anything worth printing yet: a rating, and either a
    /// contract or measurable power coming in.
    private var adapterHasSettled: Bool {
        guard power.adapterWatts != nil else { return false }
        return power.negotiatedContract != nil || (power.inputWatts ?? 0) > 0.05
    }

    /// The same charger changing rails under the same cable. Only a real change
    /// of voltage counts — the current wanders by a few milliamps constantly.
    private func noteContractChange(from previous: PowerSnapshot) {
        guard announceContract,
              let volts = power.inputVolts, volts > 1,
              let was = previous.inputVolts, was > 1,
              abs(volts - was) > 0.75
        else { return }
        post(NoticeBuilder.contractChanged(
            fromVolts: was, toVolts: volts, amps: power.inputAmps, watts: power.inputWatts
        ))
    }

    /// The battery going down while plugged in.
    ///
    /// Measured drain only, held for a while before it is said: a spike under
    /// load dips into the battery for a second or two on any charger, and a Mac
    /// held at a charge limit sits at zero flow rather than negative, so neither
    /// gets a warning. This never compares the charger against what the Mac
    /// could theoretically take.
    private func noteDrainOnCharger() {
        guard warnBatteryDrain else { return }
        guard let watts = power.batteryWatts, watts < -Self.drainWatts else {
            // Steady again: arm the warning for the next stretch of draining.
            drainingSince = nil
            drainAnnounced = false
            return
        }
        let since = drainingSince ?? Date()
        drainingSince = since
        guard !drainAnnounced, Date().timeIntervalSince(since) >= Self.drainSeconds else { return }
        drainAnnounced = true
        post(NoticeBuilder.drainingOnCharger(power))
    }

    /// Liquid found in a port, said once per stretch rather than once a second.
    ///
    /// Unlike the drain warning there is no settling period: this is the
    /// controller's own latched finding, not a measurement that can dip for a
    /// moment under load, so there is nothing to wait out.
    private func noteLiquid() {
        guard warnLiquid else { return }
        let affected = Set(ports.filter { $0.liquid?.isNoteworthy == true }.map(\.id))
        for port in ports where port.liquid?.isNoteworthy == true {
            guard !liquidAnnounced.contains(port.id) else { continue }
            post(NoticeBuilder.liquidDetected(port))
        }
        // Dropping a port that has dried out re-arms it for next time.
        liquidAnnounced = affected
    }

    /// A drain worth the name, and how long it has to hold for.
    private static let drainWatts: Double = 1
    private static let drainSeconds: TimeInterval = 45

    // MARK: - Attributing measured power to a device

    /// USB controller (locationID high byte) -> AppleHPM port number.
    ///
    /// Seeded with the layout verified on this Mac, then re-learned at runtime
    /// whenever exactly one port is occupied — which makes it self-correcting
    /// on machines with a different topology.
    private var controllerMap: [Int: Int] {
        get { PowerAttribution.storedMap }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(stored, forKey: "controllerPortMap")
        }
    }

    /// One occupied port and one active controller means the pairing is certain.
    private func learnControllerMapping() {
        let controllers = Set(result.devices.compactMap(\.controller))
        let occupied = ports.filter {
            $0.kind == .usbC && $0.isConnected && $0.number != nil && $0.outputWatts != nil
        }
        guard controllers.count == 1, occupied.count == 1,
              let controller = controllers.first, let number = occupied.first?.number,
              controllerMap[controller] != number
        else { return }

        var map = controllerMap
        map[controller] = number
        controllerMap = map
    }

    /// A port's measured VBUS belongs to a device only when that device is the
    /// sole thing on the port; behind a hub the rail is shared and unsplittable.
    private func attributeMeasuredPower() {
        learnControllerMapping()
        var devices = result.devices
        PowerAttribution.apply(to: &devices, ports: ports, map: controllerMap)
        result.devices = devices
    }

    // MARK: - Connections

    /// One card per physical connection, charger included.
    ///
    /// Ports and devices are two views of the same cable, so they are joined
    /// here rather than rendered as two lists that repeat each other's numbers.
    var connections: [Connection] {
        var claimed = Set<String>()
        var list: [Connection] = []
        let map = controllerMap

        for port in ports where port.isConnected {
            var attached: [DeviceNode] = []
            if port.kind == .usbC, let number = port.number {
                let controllers = Set(map.filter { $0.value == number }.map(\.key))
                attached = result.devices.filter { node in
                    node.controller.map(controllers.contains) ?? false
                }
                claimed.formUnion(attached.map(\.id))
            }
            list.append(connection(for: port, devices: attached))
        }

        // Thunderbolt has no controller number, and the USB map does not cover
        // every machine, so anything unplaced still gets a card of its own.
        for device in result.devices where !claimed.contains(device.id) {
            list.append(connection(forOrphan: device))
        }

        // Charger first, then things drawing power, then the merely plugged in.
        return list.enumerated()
            .sorted { ($0.element.role.rank, $0.offset) < ($1.element.role.rank, $1.offset) }
            .map(\.element)
    }

    /// The same cards, with anything that does not match the query taken out.
    ///
    /// Pure UI over the existing model — no new data, and no new scan.
    func connections(matching query: String) -> [Connection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return connections }

        return connections.compactMap { connection in
            // Searching for the hub means wanting to see what is on it, so a
            // card that matches by name keeps its whole tree.
            if connection.title.lowercased().contains(needle)
                || connection.devices.contains(where: { matches($0, needle) }) {
                return connection
            }
            let kept = keeping(connection.extraDevices, matching: needle)
            guard !kept.isEmpty else { return nil }
            var filtered = connection
            filtered.extraDevices = kept
            return filtered
        }
    }

    private func matches(_ node: DeviceNode, _ needle: String) -> Bool {
        [node.name, node.vendor ?? "", node.typeLabel ?? "", node.serial ?? ""]
            .contains { $0.lowercased().contains(needle) }
    }

    /// Keeps every match and whatever leads to it — a hit three levels into a
    /// hub still belongs under that hub, not orphaned at the root.
    private func keeping(_ rows: [FlatDevice], matching needle: String) -> [FlatDevice] {
        var keep = Set<Int>()
        for (index, row) in rows.enumerated() where matches(row.node, needle) {
            keep.insert(index)
            // Walk back up: the nearest earlier row at each shallower depth is
            // this row's parent, and so on to the root of the card.
            var depth = row.depth
            var cursor = index - 1
            while cursor >= 0, depth > 0 {
                if rows[cursor].depth < depth {
                    keep.insert(cursor)
                    depth = rows[cursor].depth
                }
                cursor -= 1
            }
        }
        return rows.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    private func connection(for port: PortInfo, devices: [DeviceNode]) -> Connection {
        let isSource = power.externalConnected && power.sourcePortName == port.name
        let role: Connection.Role = isSource ? .source : (port.isSourcing ? .sink : .idle)
        // A single device names its own card; with none or several, the port does.
        let naming = devices.count == 1 ? devices.first : nil
        // And with nothing plugged in but the charger, the charger names it —
        // "35W USB-C Power Adapter" is what that card is about, and the port it
        // arrived on is the supporting detail.
        let adapterName = naming == nil && role == .source ? power.adapterModelName : nil

        var connection = Connection(
            id: port.id,
            title: naming?.name ?? adapterName ?? port.name,
            subtitle: "",
            symbol: naming?.symbolName ?? (isSource ? "powerplug.fill" : "cable.connector")
        )
        // The mark belongs to whatever names the card. A port is not Apple, a
        // charger is — and a third-party dock fed by an Apple brick must not
        // end up with an Apple logo against its own name.
        connection.isApple = naming?.isApple
            ?? (port.kind == .magSafe || (adapterName != nil && power.isAppleAdapter))
        connection.role = role
        connection.port = port
        connection.devices = devices
        connection.extraDevices = naming.map { $0.children.flatMap { $0.flattenedRows() } }
            ?? devices.flatMap { $0.flattenedRows() }

        if isSource {
            connection.liveWatts = power.inputWatts
            connection.wattsNote = "in"
            connection.profiles = power.profiles
            connection.negotiatedProfile = power.negotiatedProfile
        } else if let watts = port.outputWatts, watts > 0.05 {
            connection.liveWatts = watts
            connection.wattsNote = "out"
        }
        connection.subtitle = subtitle(
            port: port, named: naming != nil || adapterName != nil, role: role
        )
        connection.detail = detail(
            port: port, naming: naming, role: role, titledByAdapter: adapterName != nil
        )
        if role == .source { connection.adapterRows = adapterRows }
        return connection
    }

    private func connection(forOrphan device: DeviceNode) -> Connection {
        var connection = Connection(
            id: "device-\(device.id)",
            title: device.name,
            subtitle: device.kind == .thunderbolt ? "Thunderbolt" : "USB",
            detail: [device.typeLabel, device.linkSummary]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            symbol: device.symbolName
        )
        connection.isApple = device.isApple
        connection.devices = [device]
        connection.extraDevices = device.children.flatMap { $0.flattenedRows() }
        if let watts = device.measuredWatts {
            connection.liveWatts = watts
            connection.wattsNote = "out"
        }
        return connection
    }

    /// Line one: what is happening, and where. The verb carries the direction,
    /// so the "in"/"out" beside the wattage never has to be guessed at.
    private func subtitle(port: PortInfo, named: Bool, role: Connection.Role) -> String {
        var parts: [String] = []
        switch role {
        case .source: parts.append("Charging this Mac")
        case .sink: parts.append("Powered by this Mac")
        case .idle: parts.append(port.carriesData ? "Data only, no power" : "Nothing flowing")
        }
        // When anything else names the card, the port becomes supporting detail.
        if named { parts.append(port.name) }
        return parts.joined(separator: " · ")
    }

    /// Line two: what is on the end of the cable, and how fast.
    private func detail(
        port: PortInfo,
        naming: DeviceNode?,
        role: Connection.Role,
        titledByAdapter: Bool = false
    ) -> String? {
        if role == .source {
            // A source with no name of its own gets described by what it is
            // doing instead. macOS calls a monitor feeding this Mac over
            // Type-C a "usb host", which tells nobody anything; that it is
            // pushing current without a PD contract tells them why it is 15 W.
            let described = power.adapterModelName == nil
                && port.negotiated != nil && !port.hasPDContract
                ? "Type-C source, no PD contract"
                : power.adapterName
            // The name is only worth repeating here when something else took
            // the title — otherwise the line would say the adapter twice.
            return [
                titledByAdapter ? nil : described,
                power.adapterWatts.map { String(format: "%.0f W max", $0) }
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        if let naming {
            // Vendor rides along on the card's second line rather than living
            // only in the expanded rows — it is the fastest way to tell two
            // identically-named devices apart.
            return [naming.typeLabel, naming.linkSummary, showVendors ? naming.vendor : nil]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        return port.describesCable ? port.linkSummary : nil
    }

    /// The charger's own account of itself. Apple's bricks fill all of this in;
    /// third-party PD chargers frequently report none of it, which is itself
    /// the answer to "is this an Apple charger".
    private var adapterRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let manufacturer = power.adapterManufacturer {
            rows.append(("Made by", manufacturer))
        }
        if let firmware = power.adapterFirmware {
            rows.append(("Firmware", firmware))
        }
        if let serial = power.adapterSerial {
            rows.append(("Serial", serial.middleTruncated(to: 28)))
        }
        return rows
    }

    /// The best link this Mac's ports can carry.
    var maximumTransfer: String? {
        TransportName.best(Array(Set(ports.flatMap(\.transportsSupported))))
    }

    /// The highest PD contract on offer at a connected port.
    var maximumCharging: PowerOption? {
        ports.filter(\.isConnected)
            .flatMap(\.powerOptions)
            .max { $0.watts < $1.watts }
    }

    /// Static hardware facts, compressed to one line — they never change, so
    /// they do not earn a heading and two rows in a live monitor.
    var portLimitsSummary: String? {
        var parts: [String] = []
        if let transfer = maximumTransfer { parts.append(transfer) }
        // What this Mac will accept beats what the attached charger offers:
        // it is the ceiling that does not change when you swap the brick. The
        // port's own offer stands in only for machines missing from the table.
        if let ceiling = MacModel.maximumChargeWatts {
            parts.append(String(format: "charges at up to %.0f W", ceiling))
        } else if let charging = maximumCharging {
            parts.append(String(format: "this charger offers %.0f W (%.0f V / %.2f A)",
                                charging.watts, charging.volts, charging.amps))
        }
        guard !parts.isEmpty else { return nil }
        return "This Mac: " + parts.joined(separator: " · ")
    }

    private func restartPowerTimer() {
        powerTimer?.invalidate()
        // The SMC publishes fresh numbers about once a second, and reading it
        // costs microseconds, so sample at its own rate while the panel is open.
        let interval: TimeInterval = isPresented ? 1 : 2
        powerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readPower() }
        }
    }

    /// Hardware needs a moment to enumerate after a plug event, and a dock
    /// announces its downstream devices in bursts — so scan twice, quietly.
    private func scheduleRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            refresh()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - Login item

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Wattson: login item change failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }
}
