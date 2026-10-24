// Builds the Cartouche icon sources from the SVGs in mockup/brand:
//   Cartouche.icon      Icon Composer document, Default and Dark, for actool (Assets.car)
//   Cartouche.iconset   PNGs at the macOS icon sizes, for iconutil (Cartouche.icns)
//   Glyphs.xcassets     the menu bar glyph as a template image
// usage: make-icon <brand folder> <output folder>

import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon <brand folder> <output folder>\n".utf8))
    exit(2)
}
let brand = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let files = FileManager.default

func svg(_ name: String) -> NSImage {
    let url = brand.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url), image.isValid else {
        FileHandle.standardError.write(Data("make-icon: cannot read \(url.path)\n".utf8))
        exit(1)
    }
    return image
}

// Draws the 1024-unit artwork into a square of `pixels`, inset by `inset` units on each side
func png(_ image: NSImage, pixels: Int, inset: CGFloat = 0, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
        .insetBy(dx: inset * scale, dy: inset * scale))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

func json(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

// "#FBF6EF" -> "srgb:0.98431,0.96471,0.93725,1.00000"
func srgb(_ hex: String) -> String {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    let parts = [16, 8, 0].map { String(format: "%.5f", Double((value >> UInt32($0)) & 0xFF) / 255) }
    return "srgb:" + (parts + ["1.00000"]).joined(separator: ",")
}

try? files.removeItem(at: output)

// Icon Composer document. The background gradients match the rect in cartouche-icon-*.svg.
let document = output.appendingPathComponent("Cartouche.icon", isDirectory: true)
let layers = document.appendingPathComponent("Assets", isDirectory: true)
try files.createDirectory(at: layers, withIntermediateDirectories: true)
try png(svg("cartouche-foreground-default.svg"), pixels: 1024, to: layers.appendingPathComponent("cartridge-default.png"))
try png(svg("cartouche-foreground-dark.svg"), pixels: 1024, to: layers.appendingPathComponent("cartridge-dark.png"))
try json([
    "fill-specializations": [
        ["value": ["linear-gradient": [srgb("#FBF6EF"), srgb("#EADFD1")]]],
        ["appearance": "dark", "value": ["linear-gradient": [srgb("#2A2B31"), srgb("#141518")]]],
    ],
    "groups": [[
        "layers": [[
            // actool ignores the dark entry when a plain image-name is also set
            "image-name-specializations": [
                ["value": "cartridge-default.png"],
                ["appearance": "dark", "value": "cartridge-dark.png"],
            ],
            "name": "Cartridge",
        ]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
], to: document.appendingPathComponent("icon.json"))

// macOS icons keep the shape inside 824 of 1024 units, so the full icon is inset by 100
let iconset = output.appendingPathComponent("Cartouche.iconset", isDirectory: true)
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
let icon = svg("cartouche-icon-default.svg")
for size in [16, 32, 128, 256, 512] {
    try png(icon, pixels: size, inset: 100, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(icon, pixels: size * 2, inset: 100, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// The glyph stays a vector, drawn in the menu bar's text color
let glyph = output.appendingPathComponent("Glyphs.xcassets/MenuBarGlyph.imageset", isDirectory: true)
try files.createDirectory(at: glyph, withIntermediateDirectories: true)
try json(["info": ["author": "xcode", "version": 1]],
         to: glyph.deletingLastPathComponent().appendingPathComponent("Contents.json"))
try files.copyItem(at: brand.appendingPathComponent("cartouche-glyph.svg"),
                   to: glyph.appendingPathComponent("cartouche-glyph.svg"))
try json([
    "images": [["filename": "cartouche-glyph.svg", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
], to: glyph.appendingPathComponent("Contents.json"))

print("==> Wrote \(document.lastPathComponent), \(iconset.lastPathComponent) and Glyphs.xcassets in \(output.path)")
