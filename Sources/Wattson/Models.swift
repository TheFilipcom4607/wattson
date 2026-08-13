import Foundation

/// One row in the popover: a USB or Thunderbolt device.
struct DeviceNode: Identifiable, Hashable {
    enum Kind: String {
        case usb
        case thunderbolt
    }

    /// Stable across rescans — a fresh UUID each scan would make SwiftUI throw
    /// away and rebuild every row, losing expansion state a couple of times a
    /// second. Scanner derives it from the locationID, which is stable.
    var id: String = UUID().uuidString
    /// Stable across ports and reboots, when the device offers a serial at all.
    /// Cheap hubs and card readers frequently do not, and Thunderbolt entries
    /// never do — `persistentKey` falls back to the port id for those, and
    /// their history resets when they move.
    var persistentID: String?
    var name: String
    var kind: Kind
    /// What the thing does: "Hub", "Storage", "Ethernet", ...
    var typeLabel: String?
    /// Human readable link speeds. A Thunderbolt device can expose several.
    var speeds: [String] = []
    /// "USB 3.2", "Thunderbolt 4"
    var version: String?
    var vendor: String?
    /// The device's own serial, when it publishes one. The prerequisite for
    /// `persistentID`, not a decorative extra field.
    var serial: String?
    var vendorID: Int?
    var productID: Int?
    var isApple = false
    /// Power budget granted to the device over the bus. An allocation, not a
    /// measurement — the device may draw less, or negotiate more over PD.
    var watts: Double?
    /// The same allocation as the bus states it. `watts` is this at 5 V, but mA
    /// is the figure printed on the device's own spec sheet.
    var milliamps: Double?
    /// What the device asked the bus for. Equal to `milliamps` on everything
    /// healthy, so it only earns a line when the two disagree.
    var requestedMilliamps: Double?
    /// A hub's downstream current pool: what it has to hand out, as opposed to
    /// what it draws. Hubs are excluded from the allocation total precisely
    /// because their draw is this pool, and this is that number.
    var hubBudgetMilliamps: Double?
    /// The alternate mode a billboard device is there to report — "DisplayPort".
    var altMode: String?
    var altModeVersion: String?
    /// Real VBUS draw, set only when this device is alone on its port so the
    /// port's measurement can be attributed to it unambiguously.
    var measuredWatts: Double?
    /// High byte of locationID: which USB controller, and so which port.
    var controller: Int?
    /// Fastest link in Mbit/s, for sorting and the menu bar title.
    var speedMbps: Double?
    var children: [DeviceNode] = []

    var flattenedCount: Int {
        1 + children.reduce(0) { $0 + $1.flattenedCount }
    }

    /// What anything keyed on history keys on. Falls back to the port identity,
    /// which is a weaker promise — `hasStableIdentity` says which one you got,
    /// and the UI has to admit the difference rather than paper over it.
    var persistentKey: String { persistentID ?? id }
    var hasStableIdentity: Bool { persistentID != nil }

    /// What this hub's own ports have granted out of its pool.
    ///
    /// Direct children only, and deliberately not recursive: a hub hanging off
    /// this one takes its share as a single device and then hands out a pool of
    /// its own.
    ///
    /// Nil rather than zero when nothing downstream states a draw. Plenty of
    /// devices never do — a monitor's built-in hub can have five things on it
    /// and not one of them reports an allocation — and "0 of 3100 mA granted"
    /// would read as an empty hub rather than an unanswered question.
    var grantedDownstreamMilliamps: Double? {
        guard hubBudgetMilliamps != nil else { return nil }
        let stated = children.compactMap(\.milliamps)
        guard !stated.isEmpty else { return nil }
        return stated.reduce(0, +)
    }

    /// "5.9 / 15.5 W" — short enough for the row's trailing slot, which is
    /// empty on a hub because a hub reports no draw of its own.
    ///
    /// Withheld unless the downstream devices actually said what they take: a
    /// lone pool figure in a slot that means "power drawn" everywhere else on
    /// the panel would be read as this hub drawing it.
    var hubBudgetShort: String? {
        guard let pool = hubBudgetMilliamps, let granted = grantedDownstreamMilliamps else { return nil }
        return String(format: "%.1f / %.1f W", granted * 5 / 1000, pool * 5 / 1000)
    }

    /// "1,184 of 3,100 mA granted" — what a hub has left to give, or just the
    /// size of the pool where nothing downstream will say what it takes.
    var hubBudgetSummary: String? {
        guard let pool = hubBudgetMilliamps else { return nil }
        guard let granted = grantedDownstreamMilliamps else {
            return String(format: "%.0f mA to hand out — nothing here states its draw", pool)
        }
        return String(format: "%.0f of %.0f mA granted", granted, pool)
    }

    /// Set only where the device asked for more than the bus was willing to
    /// give it — the case worth a line of its own.
    var underfedSummary: String? {
        guard let requested = requestedMilliamps, let granted = milliamps,
              requested > granted + 1
        else { return nil }
        return String(format: "%.0f mA asked for, %.0f mA granted", requested, granted)
    }

    /// "2109:0817" — the pair that names a model, as everyone writes it.
    var usbIDs: String? {
        guard let vendorID, let productID else { return nil }
        return String(format: "%04X:%04X", vendorID, productID)
    }

    /// Self and everything below it, with nesting kept as a depth so a card can
    /// render the tree without recursing.
    func flattenedRows(depth: Int = 0) -> [FlatDevice] {
        [FlatDevice(node: self, depth: depth)]
            + children.flatMap { $0.flattenedRows(depth: depth + 1) }
    }

    /// A compact one-liner, e.g. "Hub · USB 2.0".
    var subtitle: String? {
        [typeLabel, version].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// "480 Mbps" — the negotiated rate, which is the number people compare.
    ///
    /// The bcdUSB version used to ride alongside it, but "USB 2.01 · 480 Mbps"
    /// states one fact twice and cost the width that pushed vendor names off
    /// the end of the row. Version moved to the expanded rows.
    var linkSummary: String? {
        speedMbps.map(SpeedFormat.humanRate)
    }

    /// Also the card header's icon, via `Connection.symbol` — a change here
    /// shows up in both places.
    ///
    /// The tree rows ask for `.symbolVariant(.fill)` on top of this, which
    /// upgrades most of the table on its own. The two spelled out below are the
    /// ones it cannot help with: the hub's fill is infixed as `filled` rather
    /// than suffixed, and `airpodspro` is too detailed to survive at this size
    /// in any variant.
    var symbolName: String {
        if kind == .thunderbolt { return "bolt.fill" }
        switch typeLabel {
        case "Hub": return "point.3.filled.connected.trianglepath.dotted"
        case "Storage": return "externaldrive.fill"
        case "Ethernet": return "cable.connector.horizontal"
        case "Display": return "display"
        case "Audio": return "speaker.wave.2.fill"
        case "Camera": return "camera.fill"
        case "Card Reader": return "sdcard.fill"
        case "Input", "Keyboard": return "keyboard.fill"
        case "Mouse", "Trackpad": return "computermouse.fill"
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Apple Watch": return "applewatch"
        case "AirPods": return "headphones"
        default: return "cable.connector"
        }
    }

    /// Label/value pairs for a card's expanded detail.
    func detailRows(includeVendor: Bool = true) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        // The subtitle carries the bare rate; this is the descriptive form,
        // and the only place a Thunderbolt device's several speeds all show.
        if !speeds.isEmpty {
            rows.append(("Speed", speeds.joined(separator: ", ")))
        }
        if let version {
            rows.append(("Version", version))
        }
        if measuredWatts == nil, let budget = budgetSummary {
            rows.append(("Budget", budget))
        }
        if includeVendor, let vendor, !vendor.isEmpty {
            rows.append(("Vendor", vendor))
        }
        if let usbIDs {
            rows.append(("VID/PID", usbIDs))
        }
        if let serial, !serial.isEmpty {
            rows.append(("Serial", serial.middleTruncated(to: 28)))
        }
        return rows
    }

    /// The allocation, with the bus's own mA beside the watts derived from it.
    /// Both figures are the same fact; neither is a measurement.
    var budgetSummary: String? {
        guard let watts else { return nil }
        guard let milliamps else {
            return String(format: "%.1f W allocated, not measured", watts)
        }
        return String(format: "%.0f mA at 5 V (%.1f W allocated, not measured)", milliamps, watts)
    }

    /// The expanded inspector for a tree row, ordered so the power answer comes
    /// first — that is what the app is for. History is rendered separately: it
    /// is a list of events, not a label/value pair.
    func inspectorSections() -> [DeviceSection] {
        var sections: [DeviceSection] = []

        var power: [(label: String, value: String)] = []
        if let measuredWatts {
            power.append(("Measured", String(format: "%.2f W on this port", measuredWatts)))
        }
        if let watts {
            let allocation = milliamps.map { String(format: "%.0f mA at 5 V (%.1f W)", $0, watts) }
                ?? String(format: "%.1f W", watts)
            power.append(("Allocated", allocation))
        }
        if let underfed = underfedSummary {
            power.append(("Shortfall", underfed))
        }
        if let budget = hubBudgetSummary {
            power.append(("Hands out", budget))
        }
        if power.isEmpty {
            power.append(("Power", "Not reported"))
        }
        sections.append(DeviceSection(title: "Power", rows: power))

        var link: [(label: String, value: String)] = []
        if !speeds.isEmpty { link.append(("Speed", speeds.joined(separator: ", "))) }
        if let version { link.append(("Version", version)) }
        if let altMode {
            // A billboard device exists only to say this, so without it the row
            // is a mystery entry named "BILLBOARD".
            let stated = altModeVersion.map { "\(altMode) (Billboard \($0))" } ?? altMode
            link.append(("Alt mode", stated))
        }
        if !link.isEmpty { sections.append(DeviceSection(title: "Link", rows: link)) }

        var identity: [(label: String, value: String)] = []
        if let vendor, !vendor.isEmpty { identity.append(("Vendor", vendor)) }
        if let usbIDs { identity.append(("VID/PID", usbIDs)) }
        if let serial, !serial.isEmpty {
            identity.append(("Serial", serial.middleTruncated(to: 28)))
        }
        if !identity.isEmpty { sections.append(DeviceSection(title: "Identity", rows: identity)) }

        return sections
    }

    func detailLines(includeVendor: Bool = true) -> [String] {
        var lines: [String] = []
        if !speeds.isEmpty {
            lines.append("Speed: " + speeds.joined(separator: ", "))
        }
        if let measuredWatts {
            lines.append(String(format: "Power: %.2f W measured", measuredWatts))
        } else if let watts {
            let allocation = milliamps.map { String(format: "%.0f mA at 5 V, ", $0) } ?? ""
            lines.append(String(format: "Power: %@%.1f W allocated (not measured)", allocation, watts))
        }
        if includeVendor, let vendor, !vendor.isEmpty {
            lines.append("Vendor: " + vendor)
        }
        if let usbIDs {
            lines.append("VID/PID: " + usbIDs)
        }
        if let serial, !serial.isEmpty {
            lines.append("Serial: " + serial)
        }
        return lines
    }
}

/// One labelled block of a device's expanded inspector.
struct DeviceSection: Identifiable {
    let title: String
    let rows: [(label: String, value: String)]

    var id: String { title }
}

/// A device row inside a card, pre-flattened with its nesting depth.
struct FlatDevice: Identifiable {
    let node: DeviceNode
    let depth: Int

    var id: String { node.id }
}

/// One physical connection: a port, whatever is on the far end of it, and the
/// power crossing it.
///
/// Ports and devices used to be two separate lists, so a single phone on a
/// single cable was described twice — once as "Data device" on a port, once as
/// "iPhone" in the device tree — with the same wattage printed in both. One
/// cable is one card.
struct Connection: Identifiable {
    /// Which way power is moving, from the Mac's point of view.
    enum Role {
        case source  // the charger: power arriving
        case sink    // an accessory: power leaving
        case idle    // connected, but nothing worth reporting

        /// Sort order: the charger is what you opened the panel to see.
        var rank: Int {
            switch self {
            case .source: return 0
            case .sink: return 1
            case .idle: return 2
            }
        }
    }

    let id: String
    var title: String
    /// What this connection is doing, and where. One short line.
    var subtitle: String
    /// What is on the end of it, and how fast. Deliberately a second line
    /// rather than more " · " parts: one long run-on wrapped mid-figure.
    var detail: String?
    var symbol: String
    var isApple = false
    var role: Role = .idle
    var liveWatts: Double?
    /// "in" or "out", so the number's direction is never ambiguous.
    var wattsNote: String?
    var port: PortInfo?
    /// Root devices attached here.
    var devices: [DeviceNode] = []
    /// Everything below whichever device names the card, for the compact list.
    var extraDevices: [FlatDevice] = []
    var profiles: [PDProfile] = []
    var negotiatedProfile: Int?
    /// What the charger says about itself. Only the source card carries these,
    /// and only as much of them as the brick bothers to report.
    var adapterRows: [(label: String, value: String)] = []
}

struct ScanResult {
    var devices: [DeviceNode] = []
    var scannedAt = Date()

    var deviceCount: Int {
        devices.reduce(0) { $0 + $1.flattenedCount }
    }

    /// Total power budgeted to attached USB devices.
    ///
    /// Hubs are excluded: their allocation is the pool they hand out downstream,
    /// so counting both would double up.
    var allocatedWatts: Double {
        func sum(_ nodes: [DeviceNode]) -> Double {
            nodes.reduce(0) { total, node in
                let own = node.typeLabel == "Hub" ? 0 : (node.watts ?? 0)
                return total + own + sum(node.children)
            }
        }
        return sum(devices)
    }

    var fastestMbps: Double? {
        func best(_ nodes: [DeviceNode]) -> Double? {
            nodes.reduce(nil) { acc, node in
                [acc, node.speedMbps, best(node.children)].compactMap { $0 }.max()
            }
        }
        return best(devices)
    }
}

enum SpeedFormat {
    /// Negotiated USB link rates, in Mbit/s.
    private static let usbRates: [(mbps: Double, label: String)] = [
        (1.5, "Low Speed (1.5 Mbps)"),
        (12, "Full Speed (12 Mbps)"),
        (480, "High Speed (480 Mbps)"),
        (5000, "Super Speed (5 Gbps)"),
        (10_000, "Super Speed+ (10 Gbps)"),
        (20_000, "Super Speed+ (20 Gbps)"),
        (40_000, "USB4 (40 Gbps)")
    ]

    static func usbLabel(mbps: Double) -> String {
        // Tolerate slightly off-nominal reported rates.
        if let match = usbRates.first(where: { abs($0.mbps - mbps) / max($0.mbps, 1) < 0.05 }) {
            return match.label
        }
        return humanRate(mbps)
    }

    /// bcdUSB is binary coded decimal: 0x0320 means USB 3.2.
    static func usbVersion(bcd: Int) -> String {
        let major = (bcd >> 8) & 0xFF
        var minor = String(format: "%02X", bcd & 0xFF)
        // "20" -> "2", but keep "01" as "01".
        if minor.hasSuffix("0") { minor.removeLast() }
        return "USB \(major).\(minor)"
    }

    /// Thunderbolt reports strings like "Up to 40 Gb/s".
    static func thunderbolt(_ raw: String?) -> (label: String, mbps: Double)? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        var mbps: Double = 0
        if let range = lower.range(of: #"(\d+(\.\d+)?)\s*gb"#, options: .regularExpression),
           let value = Double(lower[range].replacingOccurrences(of: "gb", with: "").trimmingCharacters(in: .whitespaces)) {
            mbps = value * 1000
        } else if let range = lower.range(of: #"(\d+(\.\d+)?)\s*mb"#, options: .regularExpression),
                  let value = Double(lower[range].replacingOccurrences(of: "mb", with: "").trimmingCharacters(in: .whitespaces)) {
            mbps = value
        }

        switch mbps {
        case 40_000...: return ("Thunderbolt 4 (40 Gbps)", mbps)
        case 20_000..<40_000: return ("Thunderbolt 3 (20 Gbps)", mbps)
        case 10_000..<20_000: return ("Thunderbolt 1 (10 Gbps)", mbps)
        default: return (raw, mbps)
        }
    }

    static func humanRate(_ mbps: Double) -> String {
        if mbps >= 1000 {
            let gbps = mbps / 1000
            return gbps == gbps.rounded()
                ? String(format: "%.0f Gbps", gbps)
                : String(format: "%.1f Gbps", gbps)
        }
        return mbps == mbps.rounded()
            ? String(format: "%.0f Mbps", mbps)
            : String(format: "%.1f Mbps", mbps)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Drops the middle rather than the tail: on flash media the digits that
    /// tell two identical sticks apart are usually at the end, which is exactly
    /// what ordinary truncation would eat.
    func middleTruncated(to limit: Int) -> String {
        guard count > limit, limit > 5 else { return self }
        let head = (limit - 1) / 2
        return prefix(head) + "…" + suffix(limit - 1 - head)
    }
}

/// Ties a port's measured VBUS draw to the device responsible for it.
enum PowerAttribution {
    /// Layout verified on this Mac; DeviceModel re-learns it when it can.
    static var storedMap: [Int: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: "controllerPortMap") as? [String: Int]
        else { return [0x00: 1, 0x01: 2] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    /// Only a device alone on its port can be credited with the reading —
    /// anything behind a hub shares one rail that cannot be split.
    static func apply(to devices: inout [DeviceNode], ports: [PortInfo], map: [Int: Int]) {
        for index in devices.indices {
            devices[index].measuredWatts = nil
            guard devices[index].flattenedCount == 1,
                  let controller = devices[index].controller,
                  let number = map[controller],
                  // USB-C only: MagSafe reuses port number 1 and has no data.
                  let port = ports.first(where: { $0.kind == .usbC && $0.number == number }),
                  let watts = port.outputWatts, watts > 0.05
            else { continue }
            devices[index].measuredWatts = watts
        }
    }
}
