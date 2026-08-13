import AppKit

// Builds Wattson's icon from the supplied Photoshop artwork at every size
// macOS asks for. Run via `swift scripts/makeicon.swift <output.iconset>`.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Wattson.iconset"
try? FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

let sourcePath = "original-icon-from-photoshop.png"
guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Could not load \(sourcePath)")
}

func resizedIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero, operation: .sourceOver, fraction: 1)
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
    let image = resizedIcon(size: variant.pixels)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputPath)/\(variant.name).png"))
}

print("wrote \(variants.count) images to \(outputPath)")
