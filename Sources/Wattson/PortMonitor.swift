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

/// What a USB-PD endpoint reports in its Discover Identity response.
///
/// The chip is interrogated during PD negotiation — a cable with a free end is
/// never asked, so this is nil until something at the far end gives the Mac a
/// reason to talk to it.
///
/// This was long believed to be unreadable on `AppleHPM` machines. It is not:
/// the VDOs are published under the node's `Metadata` sub-dictionary, not at
/// the top level where every other property on the node lives, and they are
/// stored little-endian. Reading the wrong key returned nothing on every Mac,
/// which read exactly like the platform withholding the contents. Captures in
/// `probes/` carry populated VDOs going back to the first ones ever taken.
///
/// Where the node genuinely carries nothing — an empty `Metadata` is common
/// for a cable idling with nothing on its far end — `contentsWithheld` stays
/// true and nothing is claimed.
struct CableEMarker: Hashable {
    /// PD revision of the responder: 1 = PD 2.0, 2 = PD 3.0, 3 = PD 3.1 or later.
    var specificationRevision: Int?
    var vendorID: Int?
    var productID: Int?
    /// 3 = passive cable, 4 = active cable, 6 = VCONN-powered device.
    var productType: Int?
    /// The platform's own words for `productType`, when it supplies them.
    var productTypeDescription: String?
    /// Raw Discover Identity VDOs, empty where the node carries none.
    var vdos: [UInt32] = []

    /// The Cable VDO is VDO[3] of the Discover Identity response — a fixed
    /// index, not the last element. Active cables answer with five or six
    /// VDOs, so reading the last one decoded Active Cable VDO 2 as if it were
    /// the Cable VDO and reported a 40 Gbps cable's ratings from the wrong
    /// bits entirely.
    private var cableVDO: UInt32? {
        guard vdos.count > 3, productType == 3 || productType == 4 else { return nil }
        return vdos[3]
    }

    /// Bits 2:0 of the Cable VDO, per Table 6.42 (passive) / 6.43 (active).
    ///
    /// Encoding 011 is the one that moved: it meant 20 Gbps under PD 3.0 and
    /// means 40 Gbps from PD 3.1 on, so the responder's own spec revision
    /// decides which of the two a cable is claiming.
    var usbSpeed: String? {
        guard let vdo = cableVDO else { return nil }
        switch vdo & 0b111 {
        case 0b000: return "USB 2.0 — 480 Mbps"
        case 0b001: return "USB 3.2 Gen 1 — 5 Gbps"
        case 0b010: return "USB 3.2 Gen 2 — 10 Gbps"
        case 0b011: return (specificationRevision ?? 0) >= 3
            ? "USB4 Gen 3 — 40 Gbps"
            : "USB4 Gen 2×2 — 20 Gbps"
        case 0b100: return "USB4 Gen 4 — 80 Gbps"
        default: return nil
        }
    }

    /// Bits 6:5. Only 3 A and 5 A are defined; anything else is unstated.
    ///
    /// 00 is left unstated deliberately. The spec calls it invalid, but plain
    /// USB 2.0 charging cables emit it routinely as a "default", and there is
    /// nothing here to distinguish that from a cable lying about itself.
    var maxAmps: Double? {
        guard let vdo = cableVDO else { return nil }
        switch (vdo >> 5) & 0b11 {
        case 0b01: return 3
        case 0b10: return 5
        default: return nil
        }
    }

    /// Bits 10:9. Above 20 V is Extended Power Range.
    var maxVolts: Double? {
        guard let vdo = cableVDO else { return nil }
        switch (vdo >> 9) & 0b11 {
        case 0b00: return 20
        case 0b01: return 30
        case 0b10: return 40
        default: return 50
        }
    }

    /// The rating printed on the cable.
    ///
    /// The top voltage bucket is stated as 50 V but EPR itself stops at 48 V,
    /// so multiplying the bucket out gives 250 W for a cable whose jacket says
    /// 240 W. Use the range's real ceiling and the arithmetic matches the
    /// product.
    var maxWatts: Double? {
        guard let amps = maxAmps, let volts = maxVolts else { return nil }
        return amps * min(volts, 48)
    }

    /// Who made it, when the ID is one the app carries a name for.
    ///
    /// Falls back to the hex rather than to nothing: an unrecognised vendor ID
    /// is still the manufacturer's registered ID, and it is what someone would
    /// paste into a search. Nil only when the endpoint published no ID at all.
    var vendorName: String? {
        guard let vendorID else { return nil }
        return Scanner.vendorName(forID: vendorID) ?? String(format: "0x%04X", vendorID)
    }

    /// The USB-IF XID from the Cert Stat VDO, which is VDO[1]. Zero means the
    /// cable never went through certification — common, and not a fault.
    var certificationXID: UInt32? {
        guard vdos.count > 1, vdos[1] != 0 else { return nil }
        return vdos[1]
    }

    /// Nil when the responder never said which it is. Distinguishing that
    /// from "passive" matters: a node whose `Metadata` is empty published no
    /// product type at all, and reporting that as passive states something
    /// the hardware did not.
    var isActive: Bool? {
        guard let productType else { return nil }
        return productType == 4
    }

    /// Whether the responder said anything that identifies it.
    ///
    /// A spec revision alone does not count. Every one of these nodes carries
    /// one whether or not the endpoint answered, so treating it as identity
    /// would mean reporting a device on the far end of every cable, including
    /// the ones with nothing on the far end.
    var identifiesItself: Bool {
        vendorID != nil || productID != nil || productType != nil || !vdos.isEmpty
    }

    /// True when the node was found but carries nothing to decode.
    var contentsWithheld: Bool { vdos.isEmpty }
}

/// What the port controller's liquid-detection circuit reports.
///
/// Every USB-C port on an Apple silicon Mac has one: an `LDCM` node sitting
/// beside the port's other children, measuring the connector itself. macOS
/// surfaces this only as a system alert at the moment it fires, and nowhere at
/// all afterwards — so a machine that has silently disabled charging on a port
/// gives you nothing to look at.
///
/// Matched on `FeatureTypeDescription` rather than the node's class, which is
/// versioned (`AppleHPMLDCMType2` today). A future Type3 keeps working.
struct LiquidDetection: Hashable {
    /// The finding. False is a real answer here, not an absence.
    var detected = false
    /// The controller's own words for how it is being driven, e.g.
    /// "Hardware Controlled".
    var state: String?
    /// Whether the controller is allowed to act on a detection at all.
    var mitigationsEnabled = false
    /// Whether it is acting on one right now — this is what actually cuts a
    /// port's power and data.
    var mitigationsActive = false
    /// The user having told macOS to use the port anyway.
    var userOverride = false

    /// Worth saying out loud: liquid found, or the port being held down.
    var isNoteworthy: Bool { detected || mitigationsActive }

    var summary: String? {
        guard isNoteworthy else { return nil }
        if detected && mitigationsActive {
            return "Liquid detected — this port is being held down"
        }
        if detected { return "Liquid detected in this port" }
        return "This port is being held down by liquid mitigation"
    }
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
    /// The far end's own account of itself, read at the SOP address — a
    /// charger, a dock, a phone. The same Discover Identity structure, so the
    /// cable-only readings on it guard themselves: they require a product type
    /// of passive or active cable, which nothing answering here reports.
    var partner: CableEMarker?
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
    /// The Thunderbolt controller fronting this port, when there is one.
    var thunderbolt: ThunderboltLink?
    /// The connector's own liquid-detection circuit. Nil on ports that have
    /// none, which is every MagSafe port.
    var liquid: LiquidDetection?
    /// How this port's two high-speed lanes are currently assigned.
    var phy: PhyLink?
    /// The display on the other end, set only when exactly one external
    /// display and exactly one DisplayPort-carrying port make the pairing
    /// unambiguous.
    var display: DisplayInfo?

    /// The picture is being compressed to fit the link it negotiated.
    ///
    /// Stated only from the one-way inference: a mode whose uncompressed floor
    /// exceeds the link's capacity, which is nonetheless being displayed, is
    /// being compressed. Nothing is ever said about a mode that appears to fit.
    var displayCompression: String? {
        guard let display, let gbps = phy?.displayGbps else { return nil }
        return display.compressionVerdict(linkGbps: gbps)
    }

    /// Everything on this connector is on USB 2.0 because the display took
    /// both high-speed lanes. Only worth saying when something is actually
    /// connected — an idle port's lanes are parked, not contended.
    var displayIsUsingAllLanes: Bool {
        isConnected && (phy?.takesAllLanesForDisplay ?? false)
    }

    /// What the Thunderbolt link actually came up at.
    ///
    /// Gated on the port reporting an active CIO transport, which is the
    /// app's existing evidence that Thunderbolt is genuinely running. The
    /// controller's own "current" figures are not that evidence: an empty port
    /// on this Mac reports a current speed code of 8 across one lane with
    /// nothing attached, so trusting them alone would put a 10 Gbps link on
    /// every unoccupied port.
    var thunderboltAchieved: String? {
        guard transportsActive.contains("CIO") else { return nil }
        return thunderbolt?.achievedLabel
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
    ///
    /// This used to append a lane-wiring verdict derived from `pins`, which was
    /// wrong: the pin map is stale per-port state that stays behind when the
    /// cable is moved. The same cable read "USB 3.x" in one port and "USB 2.0
    /// + power only" in the other. Only what the hardware states outright is
    /// reported now.
    var cableWiringSummary: String {
        var parts = [isOpticalCable ? "Optical" : (isActiveCable ? "Active" : "Passive")]
        if let emarker {
            if emarker.contentsWithheld {
                parts.append("has an e-marker")
            } else if let speed = emarker.usbSpeed {
                parts.append(speed)
            } else {
                parts.append("e-marker read")
            }
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
        // One read for the whole machine rather than one per port.
        let thunderbolt = ThunderboltMonitor.read()
        let phys = PhyMonitor.read()
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
            // Socket ID and HPM port number are both logical numbering of the
            // same controllers, and they agree on this Mac. Neither says
            // anything about where the port is on the case — the same caveat
            // that applies to every port number here.
            if kind == .usbC, let number {
                port.thunderbolt = thunderbolt[number]
                // The PHY index is zero-based where HPM port numbers start at
                // one, and there is one of each per port. Same class of
                // assumption as every other port mapping here — and it fails
                // safe: a wrong mapping puts the lane state on a port with
                // nothing plugged into it, where it is suppressed rather than
                // shown against the wrong device.
                port.phy = phys[number - 1]
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
            collectIdentities(under: service, into: &port, depth: 0)
            collectLiquidDetection(under: service, into: &port, depth: 0)
            collectTransportState(under: service, into: &port, depth: 0)
            ports.append(port)
        }

        // Attribute the one external display to the one port carrying
        // DisplayPort, and only then. Two displays, or two ports with lanes
        // assigned, and there is nothing here that says which goes with which
        // — the same rule PowerAttribution follows for measured VBUS.
        let displays = DisplayMonitor.read()
        let carrying = ports.indices.filter { ports[$0].phy?.displayGbps != nil }
        if carrying.count == 1, let display = DisplayMonitor.soleExternal(from: displays) {
            ports[carrying[0]].display = display
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

    /// Hunts for the PD Discover Identity nodes, which hang under the port's
    /// CC child: SOP' is the chip in the cable, SOP is whatever is on the far
    /// end of it.
    ///
    /// Both are collected because a cable plugged in on its own has no far end
    /// to answer at SOP, so its e-marker answers at the SOP address instead and
    /// declares its cable identity there. Taking only SOP' missed those
    /// entirely, and taking only SOP would have mistaken a charger for a cable.
    private static func collectIdentities(under service: io_registry_entry_t, into port: inout PortInfo, depth: Int) {
        guard depth < 4 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }

            // SOP' is tested first because it is a subclass of SOP: a SOP'
            // node conforms to both, and testing the base class first would
            // file every cable chip as the thing on the far end.
            if IOObjectConformsTo(child, "IOPortTransportComponentCCUSBPDSOPp") != 0,
               let properties = properties(of: child) {
                port.emarker = preferred(port.emarker, identity(from: properties))
            } else if IOObjectConformsTo(child, "IOPortTransportComponentCCUSBPDSOP") != 0,
                      let properties = properties(of: child) {
                let responder = identity(from: properties)
                // A responder that calls itself a passive or active cable is
                // the cable, whichever address it answered at.
                if responder.productType == 3 || responder.productType == 4 {
                    port.emarker = preferred(port.emarker, responder)
                } else if responder.identifiesItself {
                    port.partner = preferred(port.partner, responder)
                }
            }
            collectIdentities(under: child, into: &port, depth: depth + 1)
        }
    }

    /// Finds the port's liquid-detection node, which sits alongside its
    /// transports rather than under them.
    private static func collectLiquidDetection(under service: io_registry_entry_t, into port: inout PortInfo, depth: Int) {
        guard depth < 3, port.liquid == nil else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let properties = properties(of: child),
               properties["FeatureTypeDescription"] as? String == "LDCM" {
                port.liquid = liquidDetection(from: properties)
                return
            }
            collectLiquidDetection(under: child, into: &port, depth: depth + 1)
            if port.liquid != nil { return }
        }
    }

    /// Decodes one `LDCM` node. Split from the walk so captures replay through it.
    static func liquidDetection(from properties: [String: Any]) -> LiquidDetection {
        var liquid = LiquidDetection()
        liquid.detected = properties["LiquidDetected"] as? Bool ?? false
        liquid.state = (properties["StateDescription"] as? String)?.nilIfEmpty
        liquid.mitigationsEnabled = properties["MitigationsEnabled"] as? Bool ?? false
        // A status of zero is the circuit sitting quiet; anything else is it
        // having taken action.
        liquid.mitigationsActive = (properties["MitigationsStatus"] as? NSNumber)?.intValue ?? 0 != 0
        liquid.userOverride = properties["UserOverrideActive"] as? Bool ?? false
        return liquid
    }

    /// Keeps whichever of two readings of the same endpoint actually says
    /// something.
    ///
    /// A port can publish more than one node for the same address, and the
    /// walk has no way to know which order it will meet them in. Assigning
    /// unconditionally meant an empty node met second could wipe out a chip
    /// that had already answered in full.
    private static func preferred(_ existing: CableEMarker?, _ candidate: CableEMarker) -> CableEMarker {
        guard let existing else { return candidate }
        if existing.contentsWithheld, !candidate.contentsWithheld { return candidate }
        return existing
    }

    /// Decodes one Discover Identity node's property dictionary.
    ///
    /// Split from the registry walk above so recorded captures can be replayed
    /// through it — `--selftest` does exactly that, and this is the function
    /// that was silently wrong for as long as it was only reachable through
    /// live hardware.
    ///
    /// The identity fields are published twice: flat on the node, and again
    /// inside `Metadata`. Only `Metadata` ever carries the VDOs, so it is read
    /// first and the flat copies are the fallback.
    static func identity(from properties: [String: Any]) -> CableEMarker {
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        var identity = CableEMarker()
        identity.specificationRevision = int(metadata["Specification Revision"])
            ?? int(properties["Specification Revision"])
        identity.vendorID = int(metadata["Vendor ID"]) ?? int(properties["Vendor ID"])
        identity.productID = int(metadata["Product ID"]) ?? int(properties["Product ID"])
        identity.productType = int(metadata["Product Type"]) ?? int(properties["Product Type"])
        identity.productTypeDescription = (metadata["Product Type Description"] as? String)
            ?? (properties["Product Type Description"] as? String)
        identity.vdos = vdos(from: metadata["VDOs"] ?? properties["VDOs"])
        return identity
    }

    /// VDOs arrive as an array of four-byte blobs, least significant byte first.
    ///
    /// The byte order is checkable without a spec to hand: the ID Header VDO
    /// carries the vendor ID in its low 16 bits, and the same node publishes
    /// that vendor ID as a plain integer alongside. Read little-endian the two
    /// agree; read the other way round they never do.
    private static func vdos(from raw: Any?) -> [UInt32] {
        guard let entries = raw as? [Any] else { return [] }
        return entries.compactMap { entry in
            if let number = entry as? NSNumber { return number.uint32Value }
            guard let data = entry as? Data, data.count >= 4 else { return nil }
            return data.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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
