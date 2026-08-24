import Foundation
import IOKit

/// What each Thunderbolt controller is, and what its link actually came up at.
///
/// Wattson could previously only say what a port is *capable* of — "Thunderbolt
/// / USB 4 (40 Gbps)" comes from the port's supported transport list and says
/// the same thing whether the port is empty or carrying a dock. This is the
/// controller's own account of the link: how many lanes it has, how fast each
/// one is, and what it settled on.
///
/// Read straight from `IOThunderboltPort`, so it costs no subprocess.
struct ThunderboltLink: Identifiable, Hashable {
    /// The controller this adapter belongs to. Each socket fronts one physical
    /// USB-C port; a socket publishes one adapter per link half, so the same
    /// socket appears more than once and the halves are folded together here.
    let socket: Int
    var id: Int { socket }

    /// A single code, not a rate: among the non-zero values, lower is faster.
    var currentSpeedCode: Int?
    var currentWidth: Int?
    /// Bitmask of the speed codes this controller can do at all.
    var supportedSpeedMask: Int?
    var supportedWidth: Int?
    var thunderboltVersion: Int?

    /// Gigabits per second per lane, from one speed code.
    ///
    /// The codes are sparse and deliberately not contiguous, so anything not
    /// listed is left unread rather than guessed at.
    private static func gbps(forCode code: Int) -> Double? {
        switch code {
        case 0x8: return 10   // Thunderbolt 3
        case 0x4: return 20   // Thunderbolt 4 / USB4
        case 0x2: return 40   // Thunderbolt 5 / USB4 v2
        default: return nil
        }
    }

    /// What the controller is built for, which is true whether or not anything
    /// is plugged in — the fastest code it says it supports, across its lanes.
    var capabilityLabel: String? {
        guard let mask = supportedSpeedMask, mask != 0 else { return nil }
        // Lower code is faster, so the fastest supported code is the lowest bit
        // set among the ones with a known meaning.
        let best = [0x2, 0x4, 0x8].first { mask & $0 != 0 }
        guard let best, let perLane = Self.gbps(forCode: best) else { return nil }
        let lanes = supportedWidth ?? 1
        let generation = best == 0x2 ? "Thunderbolt 5 / USB4 v2"
            : best == 0x4 ? "Thunderbolt 4 / USB4" : "Thunderbolt 3"
        return String(format: "%@ — %.0f Gbps", generation, perLane * Double(lanes))
    }

    /// What the link actually came up at.
    ///
    /// Deliberately not exposed unless the caller has separate evidence that
    /// Thunderbolt is really running on this port: an idle port on this Mac
    /// reports a current speed code of 8 and a width of 1 with nothing
    /// attached at all, so "10 Gbps on one lane" is what an *empty* port looks
    /// like. Reporting that as an achieved link would invent a connection.
    var achievedLabel: String? {
        guard let gbps = achievedGbps, let lanes = currentWidth else { return nil }
        return String(format: "%.0f Gbps (%d lane%@)", gbps, lanes, lanes == 1 ? "" : "s")
    }

    /// The same figure as a number, for anything that has to compare it rather
    /// than print it. Carries the same caveat: the caller needs its own
    /// evidence that Thunderbolt is running before this means anything.
    var achievedGbps: Double? {
        guard let code = currentSpeedCode, let perLane = Self.gbps(forCode: code),
              let lanes = currentWidth, lanes > 0
        else { return nil }
        return perLane * Double(lanes)
    }
}

enum ThunderboltMonitor {

    static func read() -> [Int: ThunderboltLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOThunderboltPort"), &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var properties: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let entry = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }
            properties.append(entry)
        }
        return links(from: properties)
    }

    /// Folds the adapter list into one entry per socket.
    ///
    /// Split from the walk so recorded properties replay through it. A
    /// controller publishes several adapters — DisplayPort, PCIe, USB, a
    /// native host interface — and only the ones described as a Thunderbolt
    /// Port correspond to something you can plug a cable into.
    static func links(from properties: [[String: Any]]) -> [Int: ThunderboltLink] {
        var bySocket: [Int: ThunderboltLink] = [:]
        for entry in properties {
            guard entry["Description"] as? String == "Thunderbolt Port",
                  let socketText = entry["Socket ID"] as? String,
                  let socket = Int(socketText)
            else { continue }

            var link = bySocket[socket] ?? ThunderboltLink(socket: socket)
            // A socket's two link halves report the same figures; taking the
            // wider of the two rather than the last one seen means the fold
            // does not depend on registry enumeration order.
            link.currentSpeedCode = int(entry["Current Link Speed"]) ?? link.currentSpeedCode
            link.currentWidth = max(int(entry["Current Link Width"]) ?? 0, link.currentWidth ?? 0)
            link.supportedSpeedMask = int(entry["Supported Link Speed"]) ?? link.supportedSpeedMask
            link.supportedWidth = max(int(entry["Supported Link Width"]) ?? 0, link.supportedWidth ?? 0)
            link.thunderboltVersion = int(entry["Thunderbolt Version"]) ?? link.thunderboltVersion
            bySocket[socket] = link
        }
        return bySocket
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}
