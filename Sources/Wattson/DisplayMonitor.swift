import CoreGraphics
import Foundation

/// A display the Mac is currently driving.
///
/// The mode is what macOS is actually scanning out, as opposed to what the
/// monitor or the cable could manage. Paired with the DisplayPort link rate
/// from `PhyMonitor`, it answers the question a monitor plugged into a USB-C
/// port always raises: is this running at full quality, or has something in
/// the chain quietly given up bandwidth?
struct DisplayInfo: Identifiable, Hashable {
    let id: UInt32
    var isBuiltIn = false
    /// Real scanned-out pixels, not the point size the desktop is laid out in.
    var pixelWidth = 0
    var pixelHeight = 0
    var refreshHz: Double = 0
    /// The display's registered manufacturer ID, as EDID states it.
    var vendorID: UInt32?
    var modelNumber: UInt32?
    /// `CGDisplaySerialNumber`. The same figure the port controller publishes
    /// as its `SerialNumber`, which is what lets the two accounts be joined
    /// even when two identical monitors are attached.
    var serial: UInt32?

    var modeSummary: String {
        let refresh = refreshHz > 0 ? String(format: " @ %.0f Hz", refreshHz) : ""
        return "\(pixelWidth) × \(pixelHeight)\(refresh)"
    }

    /// The floor on what this mode needs, in gigabits per second: every pixel,
    /// every second, at 8 bits per colour, plus DisplayPort's 8b/10b line
    /// coding.
    ///
    /// Deliberately a floor and not an estimate. Real timings add blanking
    /// intervals on top, and how much depends on the timing standard the
    /// display asked for, which is not published anywhere reachable. A floor
    /// is enough for the only inference worth drawing — see
    /// `cannotFitUncompressed(in:)`.
    var minimumGbps: Double? {
        guard pixelWidth > 0, pixelHeight > 0, refreshHz > 0 else { return nil }
        let pixelsPerSecond = Double(pixelWidth) * Double(pixelHeight) * refreshHz
        return pixelsPerSecond * 24 * 1.25 / 1_000_000_000
    }

    /// True when this mode provably cannot be carried uncompressed by a link
    /// of the given capacity.
    ///
    /// One-way on purpose. Exceeding the floor proves the mode does not fit,
    /// because the floor understates what the mode really needs. Coming in
    /// under the floor proves nothing at all, so nothing is claimed: a mode
    /// that looks like it fits may still not, once blanking is counted. The
    /// app never says a link is adequate, only that it demonstrably is not.
    func cannotFitUncompressed(in linkGbps: Double) -> Bool {
        guard let minimum = minimumGbps else { return false }
        return minimum > linkGbps
    }

    /// What that means in practice, given a working picture.
    ///
    /// If the mode cannot fit uncompressed and the display is nonetheless
    /// scanning it out, the link is carrying it compressed — that is what
    /// Display Stream Compression is for. This is an inference from two
    /// measured facts rather than a reading of a DSC flag, and it is stated
    /// as such.
    func compressionVerdict(linkGbps: Double) -> String? {
        guard let minimum = minimumGbps, cannotFitUncompressed(in: linkGbps) else { return nil }
        return String(
            format: "%@ needs at least %.1f Gbps uncompressed and the link carries %.1f, "
                + "so this picture is being compressed (DSC).",
            modeSummary, minimum, linkGbps
        )
    }
}

/// One display as the *port controller* sees it, which is a different account
/// from CoreGraphics's.
///
/// CoreGraphics knows the mode being scanned out and nothing about the wire.
/// The port controller knows the wire and nothing about the mode: which
/// physical port the display arrived on, what the link came up at, whether it
/// is running natively on the lanes or tunnelled inside Thunderbolt, and what
/// the monitor calls itself. Neither is complete; joined they are.
///
/// This retires a rule rather than adding to one. The display readings used to
/// require exactly one external display *and* exactly one port carrying
/// DisplayPort, because nothing said which display was on which port and
/// guessing would put a verdict against the wrong cable. `ParentBuiltInPortNumber`
/// says it outright, so the ambiguity the rule existed to avoid is not there
/// to avoid. Two identical Dell U2520Ds behind one Thunderbolt dock were what
/// showed this: same name, same product ID, same link rate, told apart by
/// serial and by nothing else.
struct DisplayLink: Hashable {
    /// The physical port this display arrived on, as the controller states it.
    var portNumber: Int
    /// Which DisplayPort stream on that port — 0 and 1 for two monitors behind
    /// one dock.
    var index: Int
    /// The monitor's own name, e.g. "DELL U2520D".
    var productName: String?
    /// The three-letter PNP code, e.g. "DEL".
    var manufacturer: String?
    var productID: Int?
    /// The EDID serial. The only thing separating two identical monitors, and
    /// the exact join key to CoreGraphics — `CGDisplaySerialNumber` reports the
    /// same value.
    var serial: UInt32?
    /// Per lane, as the controller words it: "8.1 Gbps (HBR3)".
    var linkRate: String?
    /// "DP" or "HDMI" — what the far end of the link actually is, which tells
    /// an adapter in the chain from a monitor plugged straight in.
    var connector: String?
    var isActive: Bool = false
    /// Running inside a Thunderbolt tunnel rather than natively on the port's
    /// own high-speed lanes.
    var isTunnelled: Bool = false
    var yearOfManufacture: Int?
    /// The mode CoreGraphics is scanning out on this display, matched by
    /// serial. Nil when nothing could be matched without guessing.
    var mode: DisplayInfo?

    /// "DELL U2520D — 8.1 Gbps (HBR3), tunnelled"
    var summary: String {
        var parts = [productName ?? "Display \(index)"]
        if let linkRate { parts.append(linkRate) }
        if isTunnelled { parts.append("tunnelled") }
        return parts.joined(separator: " — ")
    }
}

enum DisplayLinkMonitor {

    static func read() -> [DisplayLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOPortTransportStateDisplayPort"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var links: [DisplayLink] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS, let properties = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }
            if let link = self.link(from: properties) { links.append(link) }
        }
        return links.sorted { ($0.portNumber, $0.index) < ($1.portNumber, $1.index) }
    }

    /// Attaches each link's scanned-out mode, matched on the EDID serial.
    ///
    /// Serial only. Vendor and product would match both of a matched pair of
    /// monitors, and a mode put against the wrong one of two identical Dells is
    /// wrong in a way nobody could see — which is the failure this join exists
    /// to avoid, not one to accept quietly. A serial of zero is not an
    /// identifier and matches nothing.
    static func joinModes(_ links: [DisplayLink], displays: [DisplayInfo]) -> [DisplayLink] {
        links.map { link in
            guard let serial = link.serial, serial != 0 else { return link }
            let matches = displays.filter { $0.serial == serial }
            guard matches.count == 1 else { return link }
            var joined = link
            joined.mode = matches[0]
            return joined
        }
    }

    /// Decodes one node. Split from the walk so captures replay through it.
    ///
    /// The identity lives in `Metadata` and is also published flat, the same
    /// split the PD identity nodes have — but unlike those, both copies are
    /// populated here. `Metadata` is read first anyway, since it is the copy
    /// that carries the fields with nowhere else to live.
    static func link(from properties: [String: Any]) -> DisplayLink? {
        let metadata = properties["Metadata"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Int? {
            ((metadata[key] ?? properties[key]) as? NSNumber)?.intValue
        }
        func text(_ key: String) -> String? {
            ((metadata[key] ?? properties[key]) as? String)?.nilIfEmpty
        }
        // Without a port there is nothing to attach the display to, and the
        // whole point of this reader is the attachment.
        guard let port = (properties["ParentBuiltInPortNumber"] as? NSNumber)?.intValue,
              port > 0
        else { return nil }

        return DisplayLink(
            portNumber: port,
            index: (properties["Index"] as? NSNumber)?.intValue ?? 0,
            productName: text("ProductName"),
            manufacturer: text("ManufacturerName"),
            productID: number("ProductID"),
            serial: number("SerialNumber").map { UInt32(truncatingIfNeeded: $0) },
            linkRate: text("LinkRateDescription"),
            connector: text("DFP Type Description"),
            isActive: properties["Active"] as? Bool ?? false,
            isTunnelled: properties["Tunneled"] as? Bool ?? false,
            yearOfManufacture: number("Year of Manufacture")
        )
    }
}

enum DisplayMonitor {

    /// Every display macOS is driving, built-in included — the caller decides
    /// what to do with the internal panel, which is never on a USB-C port.
    static func read() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).compactMap { id in
            var info = DisplayInfo(id: id)
            info.isBuiltIn = CGDisplayIsBuiltin(id) != 0
            info.vendorID = CGDisplayVendorNumber(id)
            info.modelNumber = CGDisplayModelNumber(id)
            info.serial = CGDisplaySerialNumber(id)
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            info.pixelWidth = mode.pixelWidth
            info.pixelHeight = mode.pixelHeight
            info.refreshHz = mode.refreshRate
            return info
        }
    }

    /// Every value CoreGraphics publishes about every attached display, plus
    /// every mode each one offers, for the diagnostic capture.
    ///
    /// Not in `ioreg` and not reachable any other way: this reader is the one
    /// place in the app that does not go through IOKit, so a capture without
    /// this section says nothing about the display half of a USB-C link.
    ///
    /// The full mode list matters more than the current mode. "Which mode is
    /// it running" is one number; "which modes did the display offer, and did
    /// macOS pick the top one" is the question somebody actually has about a
    /// monitor on a dock, and it cannot be reconstructed after the fact.
    static func diagnosticValues() -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return "<CGGetActiveDisplayList reported no active displays>"
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return "<CGGetActiveDisplayList failed on the second call>"
        }

        return ids.prefix(Int(count)).map { id -> String in
            var lines = [
                "display id \(id)",
                "   CGDisplayIsBuiltin        = \(CGDisplayIsBuiltin(id) != 0)",
                "   CGDisplayVendorNumber     = \(CGDisplayVendorNumber(id))",
                "   CGDisplayModelNumber      = \(CGDisplayModelNumber(id))",
                "   CGDisplaySerialNumber     = \(CGDisplaySerialNumber(id))",
                "   CGDisplayUnitNumber       = \(CGDisplayUnitNumber(id))",
                "   CGDisplayPixelsWide/High  = \(CGDisplayPixelsWide(id)) x \(CGDisplayPixelsHigh(id))",
            ]
            if let mode = CGDisplayCopyDisplayMode(id) {
                lines.append("   current mode: pixelWidth=\(mode.pixelWidth) "
                    + "pixelHeight=\(mode.pixelHeight) width=\(mode.width) height=\(mode.height) "
                    + "refreshRate=\(mode.refreshRate) ioFlags=\(mode.ioFlags) "
                    + "ioDisplayModeID=\(mode.ioDisplayModeID)")
            } else {
                lines.append("   current mode: <CGDisplayCopyDisplayMode returned nothing>")
            }
            // Ask for the HiDPI modes too; without the option the list omits
            // exactly the ones a Retina-scaled monitor is actually using.
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] {
                lines.append("   \(modes.count) modes offered:")
                for mode in modes {
                    lines.append(String(
                        format: "      %5d x %-5d (points %5d x %-5d) @ %6.2f Hz  ioFlags=0x%08X  modeID=%d",
                        mode.pixelWidth, mode.pixelHeight, mode.width, mode.height,
                        mode.refreshRate, mode.ioFlags, mode.ioDisplayModeID))
                }
            } else {
                lines.append("   <CGDisplayCopyAllDisplayModes returned nothing>")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static var external: [DisplayInfo] { read().filter { !$0.isBuiltIn } }

    /// The one external display, when there is exactly one.
    ///
    /// Attribution has to be unambiguous or it is not attribution: with two
    /// monitors attached there is nothing here that says which is on which
    /// port, and guessing would put a bandwidth verdict against the wrong
    /// cable. This is the same rule `PowerAttribution` follows in crediting
    /// measured VBUS only to a device alone on its port.
    static func soleExternal(from displays: [DisplayInfo]) -> DisplayInfo? {
        let external = displays.filter { !$0.isBuiltIn }
        return external.count == 1 ? external.first : nil
    }
}
