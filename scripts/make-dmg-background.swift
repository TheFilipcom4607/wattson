// Draws the DMG window background: a faint graphite wash taken from the icon, and an arrow
// from the app to Applications. Lifted from ffmep's, recoloured: Wattson's icon is a graphite
// tile with a light glyph, and a dark window would leave Finder's black labels unreadable.
// Usage: swift make-dmg-background.swift OUT.png SCALE   (SCALE 1 or 2; the layout is 640×400 points)
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = CGSize(width: 640, height: 400)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap") }
rep.size = size

NSGraphicsContext.saveGraphicsState()
let graphics = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// The icon's tile, sampled from AppIcon.icns, and a lighter grey for the arrow's tail.
let graphite = NSColor(srgbRed: 0.157, green: 0.157, blue: 0.157, alpha: 1)
let slate = NSColor(srgbRed: 0.60, green: 0.60, blue: 0.62, alpha: 1)

ctx.setFillColor(NSColor(srgbRed: 0.975, green: 0.975, blue: 0.972, alpha: 1).cgColor)
ctx.fill(CGRect(origin: .zero, size: size))

func glow(_ color: NSColor, at center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let gradient = CGGradient(colorsSpace: sRGB,
                              colors: [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
glow(graphite, at: CGPoint(x: 40, y: 420), radius: 380, alpha: 0.07)
glow(slate, at: CGPoint(x: 330, y: -60), radius: 360, alpha: 0.08)
glow(graphite, at: CGPoint(x: 640, y: 380), radius: 400, alpha: 0.06)

// Arrow between the two icons, which sit at x 160 and 480, 190 from the top.
let y = size.height - 190
let startX: CGFloat = 262, endX: CGFloat = 378
let shaft = CGMutablePath()
shaft.move(to: CGPoint(x: startX, y: y))
shaft.addLine(to: CGPoint(x: endX - 4, y: y))
let head = CGMutablePath()
head.move(to: CGPoint(x: endX - 18, y: y + 15))
head.addLine(to: CGPoint(x: endX, y: y))
head.addLine(to: CGPoint(x: endX - 18, y: y - 15))

let arrow = CGMutablePath()
for part in [shaft, head] {
    arrow.addPath(part.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
}
ctx.saveGState()
ctx.addPath(arrow)
ctx.clip()
let arrowGradient = CGGradient(colorsSpace: sRGB, colors: [slate.cgColor, graphite.cgColor] as CFArray,
                               locations: [0, 1])!
ctx.drawLinearGradient(arrowGradient, start: CGPoint(x: startX, y: y), end: CGPoint(x: endX, y: y),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// The hint under the icons' labels.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let hint = NSAttributedString(string: "Drag Wattson to Applications to install", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 1),
    .paragraphStyle: paragraph,
])
hint.draw(in: CGRect(x: 0, y: 52, width: size.width, height: 20))

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
