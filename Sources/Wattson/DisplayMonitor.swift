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
