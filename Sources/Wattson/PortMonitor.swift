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

/// What the cable's own e-marker chip reports over SOP'.
///
/// The chip is interrogated during PD negotiation — a cable with a free end is
/// never asked, so this is nil until something at the far end gives the Mac a
/// reason to talk to it.
///
/// How much arrives depends on the Mac. Machines with an `AppleTCController`
/// publish the raw Discover Identity VDOs, which decode to the cable's speed,
/// current and voltage ratings. `AppleHPM` machines publish only the node's
/// existence — which still proves there *is* an e-marker, and that is worth
/// knowing on its own.
struct CableEMarker: Hashable {
    var specificationRevision: Int?
    var vendorID: Int?
    var productID: Int?
    /// 3 = passive cable, 4 = active cable, 6 = VCONN-powered device.
    var productType: Int?
    /// Raw Discover Identity VDOs, empty where the platform withholds them.
    var vdos: [UInt32] = []

    /// The Cable VDO is the last one in the Discover Identity response.
    private var cableVDO: UInt32? {
        guard let last = vdos.last, productType == 3 || productType == 4 else { return nil }
        return last
    }

    /// Bits 2:0 of the Cable VDO.
    var usbSpeed: String? {
        guard let vdo = cableVDO else { return nil }
        switch vdo & 0b111 {
        case 0b000: return "USB 2.0 — 480 Mbps"
        case 0b001: return "USB 3.2 Gen 1 — 5 Gbps"
        case 0b010: return "USB 3.2 Gen 2 — 10 Gbps"
        case 0b011: return "USB4 Gen 2×2 — 20 Gbps"
        case 0b100, 0b101: return "USB4 Gen 3 — 40 Gbps"
        default: return nil
        }
    }

    /// Bits 6:5. Only 3 A and 5 A are defined; anything else is "unstated".
    var maxAmps: Double? {
        guard let vdo = cableVDO else { return nil }
        switch (vdo >> 5) & 0b11 {
        case 0b01: return 3
        case 0b10: return 5
        default: return nil
        }
    }

    /// Bits 9:8. Above 20 V is Extended Power Range.
    var maxVolts: Double? {
        guard let vdo = cableVDO else { return nil }
        switch (vdo >> 8) & 0b11 {
        case 0b00: return 20
        case 0b01: return 30
        case 0b10: return 40
        default: return 50
        }
    }

    var maxWatts: Double? {
        guard let amps = maxAmps, let volts = maxVolts else { return nil }
        return amps * volts
    }

    var isActive: Bool { productType == 4 }

    /// True when the chip was found but the Mac declined to publish what it said.
    var contentsWithheld: Bool { vdos.isEmpty }
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
    /// Which mechanism actually won the power negotiation: "USB-PD", "TypeC",
    /// "Brick ID". A Type-C win means there was no PD handshake at all — the
    /// source is only advertising a current over the CC line, which is
    /// legitimate, caps at 15 W, and is worth saying out loud.
    var powerSourceKind: String?

    var hasPDContract: Bool { powerSourceKind == "USB-PD" }
    /// The cable's own chip, when the hardware has had reason to interrogate it.
    var emarker: CableEMarker?
    /// How many times anything has ever been plugged into this port. Counted by
    /// the port controller, so unlike Wattson's own log it survives reboots and
    /// covers the whole life of the machine.
    var connectionCount: Int?
    /// Which end of the data link this Mac is. "Host" almost always.
    var dataRole: String?
    /// True when a transport is carried inside USB4/Thunderbolt rather than
    /// running natively on its own wires.
    var isTunnelled = false
    /// macOS's own accessory policy, when it has something to say. The panel is
    /// otherwise unable to explain a device that enumerates and then does
    /// nothing because Privacy & Security declined it.
    var restrictionState: String?
    var restrictionProfile: String?
    var isRestricted = false
    /// "Policy Authorized" once the user has allowed the accessory; "Not
    /// Required" for anything the policy does not cover.
    var authorization: String?

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
    ///
    /// This used to append a lane-wiring verdict derived from `pins`, which was
    /// wrong: the pin map is stale per-port state that stays behind when the
    /// cable is moved. The same cable read "USB 3.x" in one port and "USB 2.0
    /// + power only" in the other. Only what the hardware states outright is
    /// reported now.
    var cableWiringSummary: String {
        var parts = [isOpticalCable ? "Optical" : (isActiveCable ? "Active" : "Passive")]
        if let emarker {
            parts.append(emarker.contentsWithheld
                ? "has an e-marker"
                : "e-marker read")
        }
        return parts.joined(separator: " · ")
    }

    /// The fastest thing known to have crossed this cable, or what its chip
    /// claims where the Mac publishes that.
    var cableCapability: String {
        if let speed = emarker?.usbSpeed { return speed }
        if let best = TransportName.best(transportsActive.filter { $0 != "CC" }) { return best }
        return "Not established"
    }

    /// What the cable is certified to carry.
    ///
    /// Only knowable when power is actually being negotiated: a contract above
    /// 3 A proves a 5 A e-marker, but with nothing feeding us there is nothing
    /// to infer from.
    var currentRating: String {
        if let watts = emarker?.maxWatts, let amps = emarker?.maxAmps {
            return String(format: "%.0f A / %.0f W — from the cable's chip", amps, watts)
        }
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
            port.connectionCount = (properties["ConnectionCount"] as? NSNumber)?.intValue

            if let pins = properties["Pin Configuration"] as? [String: Any] {
                port.pins = pins.compactMapValues { ($0 as? NSNumber)?.intValue }
            }

            collectPowerDelivery(under: service, into: &port, depth: 0)
            collectEMarker(under: service, into: &port, depth: 0)
            collectTransportState(under: service, into: &port, depth: 0)
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
            // A port offers power by several mechanisms at once — USB-PD, plain
            // Type-C current advertising, Brick ID — and exactly one of them
            // wins. Reading only the USB-PD child meant a source that never did
            // a PD handshake looked like no source at all, so a monitor feeding
            // this Mac 5 V at 3 A read as "data only" while the header counted
            // it as charging.
            if let properties = properties(of: child),
               let kind = properties["PowerSourceName"] as? String,
               let winner = (properties["WinningPowerSourceOption"] as? [String: Any]).flatMap(option),
               port.negotiated == nil || kind == "USB-PD" {
                port.negotiated = winner
                port.powerSourceKind = kind
                port.powerOptions = (properties["PowerSourceOptions"] as? [[String: Any]] ?? [])
                    .compactMap(option)
                    .sorted { $0.volts < $1.volts }
            }
            collectPowerDelivery(under: child, into: &port, depth: depth + 1)
        }
    }

    /// Per-transport state, which hangs one level below the port as a child per
    /// wire protocol — CC, USB2, DisplayPort.
    ///
    /// Each transport answers separately, and the answers are not equally
    /// interesting: the CC line is never restricted and never needs authorising,
    /// while the data transports are exactly where macOS's accessory policy
    /// shows up. So take the most specific answer any transport gives rather
    /// than whichever happens to be enumerated last.
    private static func collectTransportState(under service: io_registry_entry_t, into port: inout PortInfo, depth: Int) {
        guard depth < 3 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOPortTransportState") != 0, let properties = properties(of: child) {
                if properties["Tunneled"] as? Bool == true { port.isTunnelled = true }
                if properties["TRM_TransportRestricted"] as? Bool == true { port.isRestricted = true }
                if let role = properties["DataRoleDescription"] as? String, !role.isEmpty {
                    port.dataRole = role
                }
                if let state = properties["TRM_StateDescription"] as? String, !state.isEmpty {
                    port.restrictionState = state
                }
                if let profile = properties["TRM_ProfileDescription"] as? String, !profile.isEmpty {
                    port.restrictionProfile = profile
                }
                // "Not Required" is the default every idle transport reports;
                // anything else is the policy actually having had an opinion.
                if let status = properties["AuthorizationStatusDescription"] as? String,
                   !status.isEmpty, status != "Not Required" || port.authorization == nil {
                    port.authorization = status
                }
            }
            collectTransportState(under: child, into: &port, depth: depth + 1)
        }
    }

    /// Hunts for the cable's SOP' node, which hangs under the port's CC child.
    ///
    /// Its mere presence is the finding on most Macs: the node only exists once
    /// the hardware has actually talked to a chip in the cable. Where the
    /// platform also publishes the Discover Identity VDOs, those are decoded.
    private static func collectEMarker(under service: io_registry_entry_t, into port: inout PortInfo, depth: Int) {
        guard depth < 4 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }

            if IOObjectConformsTo(child, "IOPortTransportComponentCCUSBPDSOPp") != 0,
               let properties = properties(of: child) {
                var emarker = CableEMarker()
                emarker.specificationRevision = int(properties["Specification Revision"])
                emarker.vendorID = int(properties["Vendor ID"])
                emarker.productID = int(properties["Product ID"])
                emarker.productType = int(properties["Product Type"])
                emarker.vdos = vdos(from: properties["VDOs"])
                port.emarker = emarker
                return
            }
            collectEMarker(under: child, into: &port, depth: depth + 1)
            if port.emarker != nil { return }
        }
    }

    /// VDOs arrive as an array of four-byte blobs, most significant byte first.
    private static func vdos(from raw: Any?) -> [UInt32] {
        guard let entries = raw as? [Any] else { return [] }
        return entries.compactMap { entry in
            if let number = entry as? NSNumber { return number.uint32Value }
            guard let data = entry as? Data, data.count >= 4 else { return nil }
            return data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data {
            return data.reduce(0) { ($0 << 8) | Int($1) }
        }
        return nil
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
