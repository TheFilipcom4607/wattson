import Foundation
import IOKit

/// How a port's two high-speed lanes are actually being used right now.
///
/// A USB-C port has two SuperSpeed lane pairs, and DisplayPort alt mode takes
/// them. Take both and there is nothing left for USB 3, so everything on the
/// far end drops to USB 2.0 — which is the real answer to "why is the dock's
/// ethernet crawling when the monitor is plugged in". Nothing else on the Mac
/// tells you this: the port still advertises USB3 as a supported transport
/// because the port is still capable of it.
///
/// `AppleTypeCPhy` is the controller that assigns them. Read directly, no
/// subprocess.
struct PhyLane: Hashable {
    /// "Lane 0" / "Lane 1", as the controller names them.
    let name: String
    /// "DisplayPort", "USB3", "CIO" — what this lane is carrying.
    var transport: String?
    /// "on" when the lane is powered up.
    var powerLevel: String?
    /// The driver that claimed it, e.g. "AppleATCDPAltModePort(atc1-dpphy)".
    var client: String?

    var isActive: Bool { powerLevel == "on" && (transport?.isEmpty == false) }
}

struct PhyLink: Hashable {
    /// `AppleTypeCPhyID`, zero-based.
    let index: Int
    var lanes: [PhyLane] = []
    /// The USB 2.0 pair, which is wired separately and survives whatever the
    /// high-speed lanes are doing.
    var usb2Transport: String?
    var usb2Client: String?
    /// "8.10Gbps/lane (HBR3)" as the controller states it, for a display
    /// driven natively over the lanes.
    var displayLinkRate: String?
    /// The same, for a display tunnelled inside Thunderbolt instead.
    var displayTunnelRate: String?

    var activeLanes: [PhyLane] { lanes.filter(\.isActive) }

    /// The lane assignment in one phrase: "Both lanes: DisplayPort".
    var laneSummary: String? {
        let active = activeLanes
        guard !active.isEmpty else { return nil }
        let transports = Set(active.compactMap(\.transport))
        let count = active.count
        let noun = count == 1 ? "1 lane" : count == 2 ? "Both lanes" : "\(count) lanes"
        if transports.count == 1, let only = transports.first {
            return "\(noun): \(only)"
        }
        return "\(noun): " + active.compactMap(\.transport).joined(separator: " + ")
    }

    /// Gigabits per second per lane and the DisplayPort rate name, pulled out
    /// of the controller's own string rather than mapped from a table — the
    /// string already carries both, and parsing it cannot invent a rate the
    /// hardware did not report.
    private static func rate(_ text: String?) -> (perLane: Double, name: String)? {
        guard let text else { return nil }
        // Leading number, however many digits and decimals it has. Foundation's
        // Scanner is shadowed here by the app's own device Scanner.
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"),
              open < close
        else { return (value, "") }
        return (value, String(text[text.index(after: open)..<close]))
    }

    /// What the display link adds up to across the lanes carrying it.
    ///
    /// Only counts lanes actually assigned to DisplayPort: the rate is stated
    /// per lane, so multiplying by a lane count that includes a lane doing
    /// something else would report bandwidth that does not exist.
    var displaySummary: String? {
        guard let rate = Self.rate(displayLinkRate) ?? Self.rate(displayTunnelRate) else { return nil }
        let lanes = activeLanes.filter { $0.transport == "DisplayPort" }.count
        let suffix = rate.name.isEmpty ? "" : " \(rate.name)"
        guard lanes > 0 else {
            return String(format: "%.2f Gbps per lane%@", rate.perLane, suffix)
        }
        return String(format: "%.1f Gbps over %d lane%@%@",
                      rate.perLane * Double(lanes), lanes, lanes == 1 ? "" : "s", suffix)
    }

    /// The display link's total capacity in gigabits per second, across the
    /// lanes actually carrying it. Nil when no display is on these lanes.
    var displayGbps: Double? {
        guard let rate = Self.rate(displayLinkRate) ?? Self.rate(displayTunnelRate) else { return nil }
        let lanes = activeLanes.filter { $0.transport == "DisplayPort" }.count
        guard lanes > 0 else { return nil }
        return rate.perLane * Double(lanes)
    }

    /// The consequence worth stating outright.
    ///
    /// Both lanes on DisplayPort means USB 3 has no wires left, so anything
    /// hanging off the same connector is on USB 2.0 whether or not it is
    /// capable of more.
    var takesAllLanesForDisplay: Bool {
        let active = activeLanes
        return active.count >= 2 && active.allSatisfy { $0.transport == "DisplayPort" }
    }
}

enum PhyMonitor {

    static func read() -> [Int: PhyLink] {
        var iterator: io_iterator_t = 0
        // The superclass, not the chip-specific subclass: this is
        // AppleT8132TypeCPhy on an M4 and something else on the next one.
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleTypeCPhy"), &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var links: [Int: PhyLink] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let link = phy(from: properties)
            else { continue }
            links[link.index] = link
        }
        return links
    }

    /// Decodes one `AppleTypeCPhy` property dictionary. Split from the walk so
    /// captures replay through it — the populated shape only exists while a
    /// display is attached, which is not a state a test machine is often in.
    static func phy(from properties: [String: Any]) -> PhyLink? {
        guard let index = (properties["AppleTypeCPhyID"] as? NSNumber)?.intValue else { return nil }
        var link = PhyLink(index: index)

        if let lanes = properties["AppleTypeCPhyLane"] as? [String: Any] {
            // Sorted so "Lane 0" precedes "Lane 1" whatever order the
            // dictionary hands them over in.
            for name in lanes.keys.sorted() {
                guard let entry = lanes[name] as? [String: Any] else { continue }
                var lane = PhyLane(name: name)
                lane.transport = (entry["Transport"] as? String)?.nilIfEmpty
                lane.powerLevel = (entry["Power Level"] as? String)?.nilIfEmpty
                lane.client = (entry["Client"] as? String)?.nilIfEmpty
                link.lanes.append(lane)
            }
        }
        if let usb2 = properties["AppleTypeCPhyUSB2"] as? [String: Any] {
            link.usb2Transport = (usb2["Transport"] as? String)?.nilIfEmpty
            link.usb2Client = (usb2["Client"] as? String)?.nilIfEmpty
        }
        link.displayLinkRate = firstLinkRate(in: properties["AppleTypeCPhyDisplayPortPclk"])
        link.displayTunnelRate = firstLinkRate(in: properties["AppleTypeCPhyDisplayPortTunnel"])
        return link
    }

    /// The rate string out of a dictionary of numbered children — "PCLK 1",
    /// "Tunnel 0" — each of which carries its own `Link Rate`.
    private static func firstLinkRate(in raw: Any?) -> String? {
        guard let container = raw as? [String: Any] else { return nil }
        for key in container.keys.sorted() {
            guard let child = container[key] as? [String: Any],
                  let rate = (child["Link Rate"] as? String)?.nilIfEmpty
            else { continue }
            return rate
        }
        return nil
    }
}
