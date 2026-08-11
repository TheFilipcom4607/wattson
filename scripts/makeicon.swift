import AppKit

// Renders Wattson's app icon: a bolt on a rounded blue-violet tile, at every
// size macOS asks for. Run via `swift scripts/makeicon.swift <output.iconset>`.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Wattson.iconset"
try? FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icons sit inset inside their canvas.
    let inset = size * 0.06
    let tile = rect.insetBy(dx: inset, dy: inset)
    let corner = tile.width * 0.2237

    let path = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.52, green: 0.26, blue: 0.90, alpha: 1)
        ]
    )?.draw(in: path, angle: -90)

    // A bolt, drawn as a polygon so it needs no font or symbol lookup.
    let width = tile.width
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (0.56, 0.90), (0.30, 0.50), (0.46, 0.50),
        (0.42, 0.12), (0.70, 0.53), (0.53, 0.53)
    ]
    for (index, point) in points.enumerated() {
        let location = NSPoint(x: tile.minX + point.0 * width, y: tile.minY + point.1 * width)
        index == 0 ? bolt.move(to: location) : bolt.line(to: location)
    }
    bolt.close()

    NSColor(calibratedWhite: 1, alpha: 0.97).setFill()
    bolt.fill()

    image.unlockFocus()
    return image
}

// The sizes iconutil expects in an .iconset.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let image = drawIcon(size: variant.pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputPath)/\(variant.name).png"))
}

print("wrote \(variants.count) images to \(outputPath)")
