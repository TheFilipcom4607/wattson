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
    var name: String
    var kind: Kind
    /// What the thing does: "Hub", "Storage", "Ethernet", ...
    var typeLabel: String?
    /// Human readable link speeds. A Thunderbolt device can expose several.
    var speeds: [String] = []
    /// "USB 3.2", "Thunderbolt 4"
    var version: String?
    var vendor: String?
    var isApple = false
    /// Power budget granted to the device over the bus. An allocation, not a
    /// measurement — the device may draw less, or negotiate more over PD.
    var watts: Double?
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

    /// "USB 2.1 · 480 Mbps" — short enough for a card subtitle.
    var linkSummary: String? {
        [version, speedMbps.map(SpeedFormat.humanRate)]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    var symbolName: String {
        if kind == .thunderbolt { return "bolt.fill" }
        switch typeLabel {
        case "Hub": return "point.3.connected.trianglepath.dotted"
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
        case "AirPods": return "airpodspro"
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
        if measuredWatts == nil, let watts {
            rows.append(("Budget", String(format: "%.1f W allocated, not measured", watts)))
        }
        if includeVendor, let vendor, !vendor.isEmpty {
            rows.append(("Vendor", vendor))
        }
        return rows
    }

    func detailLines(includeVendor: Bool = true) -> [String] {
        var lines: [String] = []
        if !speeds.isEmpty {
            lines.append("Speed: " + speeds.joined(separator: ", "))
        }
        if let measuredWatts {
            lines.append(String(format: "Power: %.2f W measured", measuredWatts))
        } else if let watts {
            lines.append(String(format: "Power: %.1f W allocated (not measured)", watts))
        }
        if includeVendor, let vendor, !vendor.isEmpty {
            lines.append("Vendor: " + vendor)
        }
        return lines
    }
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
