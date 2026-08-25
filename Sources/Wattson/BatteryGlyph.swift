import AppKit
import SwiftUI

/// The battery, drawn from the figure rather than picked out of a set of
/// pictures.
///
/// SF Symbols ships battery art in five steps — 0, 25, 50, 75, 100 — so a
/// symbol can only ever round 61% to the nearest quarter, which is no use to
/// anyone trying to read a charge level off it. These are the proportions of
/// the battery macOS draws in its own menu bar, so this one can take its place.
enum BatteryGlyph {

    /// Proportions of the drawn battery, in points. The defaults are menu bar
    /// sized — measured against `battery.100percent`, which is 26 x 12 at the
    /// point size the menu bar uses, so this one sits beside the system's own
    /// battery at the same weight rather than a size down from it.
    struct Metrics {
        var bodyWidth: CGFloat = 24
        var bodyHeight: CGFloat = 12.4
        var lineWidth: CGFloat = 1.3
        var cornerRadius: CGFloat = 4
        /// The nub on the positive end.
        var capWidth: CGFloat = 2
        var capHeight: CGFloat = 5.2
        var capGap: CGFloat = 1.1
        /// Clearance between the outline and the charge inside it.
        var inset: CGFloat = 2.1
        /// The gap held open around the bolt, so it reads against a full cell.
        var clearance: CGFloat = 0.85

        static let menuBar = Metrics()

        /// The same battery, drawn taller. Everything scales together, so the
        /// icon in the menu bar and the gauge in the panel cannot drift apart.
        func scaled(toHeight height: CGFloat) -> Metrics {
            let factor = height / bodyHeight
            var scaled = self
            scaled.bodyWidth *= factor
            scaled.bodyHeight = height
            scaled.lineWidth *= factor
            scaled.cornerRadius *= factor
            scaled.capWidth *= factor
            scaled.capHeight *= factor
            scaled.capGap *= factor
            scaled.inset *= factor
            scaled.clearance *= factor
            return scaled
        }

        var width: CGFloat { bodyWidth + capGap + capWidth }
        var height: CGFloat { bodyHeight }
        var size: CGSize { CGSize(width: width, height: height) }
        var interiorWidth: CGFloat { bodyWidth - inset * 2 }
        var interiorHeight: CGFloat { bodyHeight - inset * 2 }
    }

    // MARK: - Geometry
    //
    // Every path below is in the glyph's own space: origin top left, y down,
    // which is what SwiftUI uses and what a flipped AppKit context gives.

    /// The outline, as a path to be stroked at `lineWidth`.
    static func bodyPath(_ m: Metrics) -> CGPath {
        let rect = CGRect(
            x: m.lineWidth / 2,
            y: m.lineWidth / 2,
            width: m.bodyWidth - m.lineWidth,
            height: m.bodyHeight - m.lineWidth
        )
        return CGPath(
            roundedRect: rect,
            cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius, transform: nil
        )
    }

    static func capPath(_ m: Metrics) -> CGPath {
        let rect = CGRect(
            x: m.bodyWidth + m.capGap,
            y: (m.bodyHeight - m.capHeight) / 2,
            width: m.capWidth,
            height: m.capHeight
        )
        return CGPath(
            roundedRect: rect,
            cornerWidth: m.capWidth / 2, cornerHeight: m.capWidth / 2, transform: nil
        )
    }

    /// The charge inside the outline.
    static func chargePath(_ m: Metrics, percent: Int) -> CGPath {
        let width = chargeWidth(m, percent: percent)
        guard width > 0 else { return CGMutablePath() }
        let radius = max(min(m.cornerRadius - m.inset * 0.6, width / 2, m.interiorHeight / 2), 0)
        let rect = CGRect(x: m.inset, y: m.inset, width: width, height: m.interiorHeight)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// How wide the charge is at this level. Never a hairline: a nearly flat
    /// battery still has to read as a battery with a little left in it rather
    /// than as an empty outline with a smudge in one end. The floor is kept
    /// low enough that 5% and 20% do not draw as the same picture.
    static func chargeWidth(_ m: Metrics, percent: Int) -> CGFloat {
        let fraction = min(max(Double(percent), 0), 100) / 100
        guard fraction > 0 else { return 0 }
        return max(m.interiorWidth * fraction, m.interiorHeight * 0.34)
    }

    /// A lightning bolt, as fractions of its own box.
    private static let boltPoints: [CGPoint] = [
        CGPoint(x: 0.62, y: 0.00),
        CGPoint(x: 0.08, y: 0.58),
        CGPoint(x: 0.42, y: 0.58),
        CGPoint(x: 0.34, y: 1.00),
        CGPoint(x: 0.92, y: 0.42),
        CGPoint(x: 0.56, y: 0.42)
    ]

    /// Centred in the body and very nearly as tall as it, the way Apple's own
    /// is: a bolt that fits inside the charge is too small to read at menu bar
    /// size. It is the moat below that keeps it legible where it crosses the
    /// outline, so it does not have to stay clear of it.
    static func boltPath(_ m: Metrics) -> CGPath {
        let height = m.bodyHeight - m.lineWidth * 1.5
        let width = height * 0.56
        let origin = CGPoint(x: (m.bodyWidth - width) / 2, y: (m.bodyHeight - height) / 2)
        let path = CGMutablePath()
        for (index, point) in boltPoints.enumerated() {
            let at = CGPoint(x: origin.x + point.x * width, y: origin.y + point.y * height)
            if index == 0 {
                path.move(to: at)
            } else {
                path.addLine(to: at)
            }
        }
        path.closeSubpath()
        return path
    }

    /// The three regions a battery is made of, each ready to fill.
    ///
    /// The bolt is not laid over the charge, it is cut out of everything behind
    /// it — outline included — with a gap held open around it, and then drawn
    /// back inside that gap. That is what lets one bolt read against a full
    /// cell and an empty one: on a full battery you see the gap in the shape of
    /// a bolt, on an empty one you see the bolt itself.
    struct Parts {
        /// Outline and cap.
        let shell: CGPath
        /// What is left in the cell.
        let charge: CGPath
        /// Nil unless power is going in.
        let bolt: CGPath?
    }

    static func parts(_ m: Metrics, percent: Int, charging: Bool) -> Parts {
        let outline = bodyPath(m)
            .copy(strokingWithWidth: m.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        var shell = outline.union(capPath(m))
        var charge = chargePath(m, percent: percent)

        guard charging else { return Parts(shell: shell, charge: charge, bolt: nil) }

        let bolt = boltPath(m)
        let moat = bolt.union(bolt.copy(
            strokingWithWidth: m.clearance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10
        ))
        shell = shell.subtracting(moat)
        charge = charge.subtracting(moat)
        return Parts(shell: shell, charge: charge, bolt: bolt)
    }

    // MARK: - Menu bar

    /// The menu bar icon.
    ///
    /// Normally a template image: black with alpha, which the system tints for
    /// a light or dark menu bar. Low Power Mode is the exception — the charge
    /// goes yellow, as the system's own battery does, and a coloured image
    /// cannot be a template. So the outline has to resolve its own colour, and
    /// `setFill` does exactly that: an `NSColor` resolves against whatever
    /// appearance is drawing at the time, so a yellow icon still follows a menu
    /// bar from light to dark.
    static func menuBarImage(percent: Int, charging: Bool, lowPower: Bool) -> NSImage {
        let m = Metrics.menuBar
        let image = NSImage(size: m.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let parts = parts(m, percent: percent, charging: charging)

            // The outline is held back from full strength either way, to let
            // the charge inside it be the part you read.
            let ink = lowPower ? NSColor.labelColor : NSColor.black
            ink.withAlphaComponent(0.55).setFill()
            context.addPath(parts.shell)
            context.fillPath()

            (lowPower ? NSColor.systemYellow : NSColor.black).setFill()
            context.addPath(parts.charge)
            context.fillPath()
            if let bolt = parts.bolt {
                context.addPath(bolt)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = !lowPower
        image.accessibilityDescription = lowPower
            ? "Battery \(percent)%, Low Power Mode"
            : "Battery \(percent)%"
        return image
    }
}

/// The battery at panel size and in colour, next to the percentage it stands for.
struct BatteryGauge: View {
    let percent: Int
    let charging: Bool
    var lowPower = false
    var height: CGFloat = 15

    private var chargeColor: Color {
        // Low Power Mode outranks the rest, as it does in the system's own
        // battery: it is a mode you have put the machine in, and the bolt still
        // says whether it is charging.
        if lowPower { return .yellow }
        if charging { return .green }
        // The level the system itself starts warning at. Being plugged in is
        // not enough to earn a pass: a machine at 14% and still going down on
        // a charger that cannot keep up is the case worth colouring.
        if percent <= 20 { return .red }
        return .primary
    }

    var body: some View {
        let m = BatteryGlyph.Metrics.menuBar.scaled(toHeight: height)
        let parts = BatteryGlyph.parts(m, percent: percent, charging: charging)
        return ZStack(alignment: .topLeading) {
            GlyphPath(parts.shell).fill(Color.primary.opacity(0.4))
            GlyphPath(parts.charge).fill(chargeColor)
            if let bolt = parts.bolt {
                GlyphPath(bolt).fill(chargeColor)
            }
        }
        .frame(width: m.width, height: m.height)
        // A shape with no text in it, so the label is the whole reading. The
        // charge state was missing from it: a bolt drawn through the fill is
        // the only thing that distinguished 73% going up from 73% going down,
        // and a drawing is exactly what a screen reader cannot see.
        .accessibilityLabel(
            "Battery \(percent) percent"
                + (charging ? ", charging" : "")
                + (lowPower ? ", Low Power Mode" : "")
        )
    }
}

/// One of the glyph's paths as a Shape, so the menu bar icon and the gauge are
/// drawn from the same geometry rather than from two drawings of one battery.
private struct GlyphPath: Shape {
    let shape: Path

    init(_ cgPath: CGPath) { shape = Path(cgPath) }

    func path(in rect: CGRect) -> Path { shape }
}
