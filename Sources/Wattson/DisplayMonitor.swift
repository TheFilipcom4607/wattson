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
