import Foundation
import IOKit

/// One fixed voltage/current pair a source advertises.
struct PowerOption: Identifiable, Hashable {
    let id = UUID()
    let milliamps: Double
    let milliwatts: Double

    var volts: Double { milliamps > 0 ? milliwatts / milliamps : 0 }
    var amps: Double { milliamps / 1000 }
    var watts: Double { milliwatts / 1000 }
}

/// The state of one physical port on the Mac.
struct PortInfo: Identifiable, Hashable {
    /// Port numbers repeat across types — MagSafe is also port 1 — so the kind
    /// has to be carried alongside the number to identify a port.
    enum Kind: String {
        case usbC
        case magSafe
        case other
    }

    /// Stable across polls. PortMonitor rebuilds every PortInfo once a second,
    /// so a per-instance UUID would give SwiftUI a brand new identity each time
    /// and reset anything held per-card, like whether it is expanded.
    /// Falls back to the name so two ports that both report no number cannot
    /// collide — duplicate ids inside a ForEach misrender silently.
    var id: String { "\(kind.rawValue)-\(number.map(String.init) ?? name)" }
    var name: String
    var kind: Kind = .other
    /// Port number as AppleHPM reports it; unique only within a kind.
    var number: Int?
    var isConnected: Bool
    /// Measured power flowing out to whatever is attached.
    var outputVolts: Double?
    var outputAmps: Double?
    var outputWatts: Double?
    /// What the link is carrying right now.
    var transportsActive: [String] = []
    /// What the port itself is capable of.
    var transportsSupported: [String] = []
    var isActiveCable = false
    var isOpticalCable = false
    /// Lane assignments; a lane wired as 0 is not connected through the cable.
    var pins: [String: Int] = [:]
    var powerOptions: [PowerOption] = []
    var negotiated: PowerOption?

    /// Both SuperSpeed pairs carried through the cable.
    var hasSuperSpeedLanes: Bool {
        (pins["rx2"] ?? 0) != 0 && (pins["tx2"] ?? 0) != 0
    }

    /// The sideband pins DisplayPort alt mode and Thunderbolt need.
    var hasSidebandPins: Bool {
        (pins["sbu1"] ?? 0) != 0 || (pins["sbu2"] ?? 0) != 0
    }

    /// >3 A is only legal over a cable whose e-marker declares 5 A.
    var isFiveAmpRated: Bool {
        (negotiated?.milliamps ?? 0) > 3000
    }

    /// Whether anything is moving data, as opposed to only drawing power.
    var carriesData: Bool {
        !transportsActive.filter { $0 != "CC" }.isEmpty
    }

    /// The Mac is feeding this port, rather than being fed by it.
    var isSourcing: Bool { (outputWatts ?? 0) > 0.05 }

    /// What is on the far end, which is not always just a cable.
    var attachedHeadline: String {
        if kind == .magSafe { return "MagSafe 3 power cable" }
        switch (carriesData, negotiated != nil) {
        case (true, true): return "Device + power source"
        case (true, false): return "Data device"
        case (false, true): return "Power source"
        case (false, false): return "Cable only — nothing negotiated"
        }
    }

    /// MagSafe carries power only, so USB-C lane and transport rows are noise.
    var describesCable: Bool { kind == .usbC }

    /// How the cable itself is built.
    var cableWiringSummary: String {
        if isOpticalCable { return "Optical · \(wiringDetail)" }
        let kind = isActiveCable ? "Active" : "Passive"
        return "\(kind) · \(wiringDetail)"
    }

    /// The best this wiring could carry.
    ///
    /// Inferred from lane wiring, not read from the cable's e-marker: macOS does
    /// not publish the cable's identity response. What it actually negotiates is
    /// only known once a data device runs through it.
    var cableCapability: String {
        if hasSuperSpeedLanes {
            return hasSidebandPins ? "Thunderbolt / USB4 capable" : "USB 3.x, no DisplayPort"
        }
        return "USB 2.0 (480 Mbps) + power only"
    }

    /// Which physical conductors run through the cable.
    var wiringDetail: String {
        hasSuperSpeedLanes
            ? (hasSidebandPins ? "4 SuperSpeed lanes + SBU" : "4 SuperSpeed lanes, no SBU")
            : "USB 2.0 pair only"
    }

    /// What the cable is certified to carry.
    ///
    /// Only knowable when power is actually being negotiated: a contract above
    /// 3 A proves a 5 A e-marker, but with nothing feeding us there is nothing
    /// to infer from.
    var currentRating: String {
        if isFiveAmpRated { return "e-marked for 5 A (100 W+)" }
        // Sourcing tells us nothing about the e-marker: the Mac caps its own
        // output at 3 A regardless of what the cable could take. Saying "no
        // charger attached" here read as a contradiction whenever a charger was
        // plugged into the *other* port.
        if negotiated == nil {
            return isSourcing ? "n/a — this Mac is the source" : "Unknown — nothing negotiated"
        }
        return "Up to 3 A (60 W)"
    }


    var activeSummary: String {
        let data = transportsActive.filter { $0 != "CC" }
        if data.isEmpty {
            return isConnected ? "Power/config only — no data link" : "Nothing connected"
        }
        return data.map(TransportName.pretty).joined(separator: ", ")
    }

    /// The same fact as `activeSummary`, short enough for a card subtitle.
    var linkSummary: String {
        let data = transportsActive.filter { $0 != "CC" }
        if data.isEmpty { return isConnected ? "No data link" : "Nothing connected" }
        return data.map(TransportName.pretty).joined(separator: ", ")
    }
}

enum TransportName {
    static func pretty(_ raw: String) -> String {
        switch raw {
        case "CC": return "Configuration channel"
        case "USB2": return "USB 2.0 (480 Mbps)"
        case "USB3": return "USB 3.x (up to 10 Gbps)"
        case "CIO": return "Thunderbolt / USB4 (40 Gbps)"
        case "DisplayPort": return "DisplayPort"
        default: return raw
        }
    }

    /// The fastest thing a port's supported list implies.
    static func best(_ supported: [String]) -> String? {
        if supported.contains("CIO") { return "Thunderbolt / USB 4 (40 Gbps)" }
        if supported.contains("USB3") { return "USB 3.x (up to 10 Gbps)" }
        if supported.contains("USB2") { return "USB 2.0 (480 Mbps)" }
        return nil
    }
}

/// Reads Apple's USB-C port controller (AppleHPM) out of the IORegistry.
enum PortMonitor {

    static func read() -> [PortInfo] {
        var iterator: io_iterator_t = 0
        // AppleHPMInterface is the shared superclass of the USB-C and MagSafe ports.
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleHPMInterface"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let vbus = SMCMonitor.portPower()
        var ports: [PortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let properties = properties(of: service),
                  let description = properties["PortDescription"] as? String
            else { continue }

            let number = (properties["PortNumber"] as? NSNumber)?.intValue
            let kind: PortInfo.Kind = description.contains("USB-C") ? .usbC
                : description.contains("MagSafe") ? .magSafe : .other
            var port = PortInfo(
                name: displayName(description),
                kind: kind,
                number: number,
                isConnected: properties["ConnectionActive"] as? Bool ?? false
            )
            // MagSafe has no VBUS rail, and shares port number 1 with USB-C.
            if kind == .usbC, let number, let power = vbus[number] {
                port.outputVolts = power.volts
                port.outputAmps = power.amps
                port.outputWatts = power.watts
            }
            port.transportsActive = properties["TransportsActive"] as? [String] ?? []
            port.transportsSupported = properties["TransportsSupported"] as? [String] ?? []
            port.isActiveCable = properties["ActiveCable"] as? Bool ?? false
            port.isOpticalCable = properties["OpticalCable"] as? Bool ?? false

            if let pins = properties["Pin Configuration"] as? [String: Any] {
                port.pins = pins.compactMapValues { ($0 as? NSNumber)?.intValue }
            }

            collectPowerDelivery(under: service, into: &port, depth: 0)
            ports.append(port)
        }

        // Connected ports first, then by name, so the interesting one is on top.
        return ports.sorted {
            $0.isConnected == $1.isConnected ? $0.name < $1.name : $0.isConnected
        }
    }

    /// The PD contract hangs a couple of levels below the port, under "Power In".
    private static func collectPowerDelivery(under service: io_registry_entry_t, into port: inout PortInfo, depth: Int) {
        guard depth < 3 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let properties = properties(of: child),
               properties["PowerSourceName"] as? String == "USB-PD" {
                port.powerOptions = (properties["PowerSourceOptions"] as? [[String: Any]] ?? [])
                    .compactMap(option)
                    .sorted { $0.volts < $1.volts }
                port.negotiated = (properties["WinningPowerSourceOption"] as? [String: Any]).flatMap(option)
            }
            collectPowerDelivery(under: child, into: &port, depth: depth + 1)
        }
    }

    private static func option(_ raw: [String: Any]) -> PowerOption? {
        guard let mA = (raw["Max Current (mA)"] as? NSNumber)?.doubleValue,
              let mW = (raw["Max Power (mW)"] as? NSNumber)?.doubleValue,
              mA > 0, mW > 0
        else { return nil }
        return PowerOption(milliamps: mA, milliwatts: mW)
    }

    /// "Port-USB-C@1" -> "USB-C (front)", "Port-MagSafe 3@1" -> "MagSafe 3"
    ///
    /// Port numbering says nothing about physical position, so the mapping was
    /// established by hand on this Mac: port 2 sits beside MagSafe, port 1 is
    /// the one toward the front edge. Both are on the left side.
    ///
    /// Parenthesised rather than "USB-C · nearer you" because these names are
    /// joined into " · "-separated subtitles, where a name containing its own
    /// separator reads as two fields.
    private static func displayName(_ description: String) -> String {
        let body = description.replacingOccurrences(of: "Port-", with: "")
        let parts = body.split(separator: "@")
        let kind = String(parts.first ?? "Port")
        guard kind == "USB-C", let index = parts.last else { return kind }

        switch index {
        case "1": return "USB-C (front)"
        case "2": return "USB-C (rear)"
        default: return "USB-C \(index)"
        }
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }
}
