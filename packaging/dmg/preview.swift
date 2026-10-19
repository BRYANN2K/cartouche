// Draws what the disk image window looks like, from the same background and
// icon positions, for the README.
//
//   swift packaging/dmg/preview.swift <repository> <out.png>

import AppKit

let repo = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
let out = URL(filePath: CommandLine.arguments[2])
let content = CGSize(width: 660, height: 400)
let titleBar: CGFloat = 28
let scale: CGFloat = 2
let size = CGSize(width: content.width, height: content.height + titleBar)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
cg.translateBy(x: 0, y: size.height * scale)
cg.scaleBy(x: scale, y: -scale)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

let frame = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
frame.addClip()
NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1).setFill()
CGRect(origin: .zero, size: size).fill()
for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: 14 + CGFloat(i) * 20, y: 8, width: 12, height: 12)).fill()
}
let title = NSAttributedString(string: "Cartouche", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
title.draw(at: CGPoint(x: (size.width - title.size().width) / 2, y: 6))

let background = NSImage(contentsOf: repo.appending(path: "packaging/dmg/background@2x.png"))!
background.draw(in: CGRect(x: 0, y: titleBar, width: content.width, height: content.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

let icon = NSImage(contentsOf: repo.appending(path: "mockup/brand/cartouche-icon-default.svg"))!
let folder = NSWorkspace.shared.icon(forFile: "/Applications")
for (image, label, x) in [(icon, "Cartouche", 170.0), (folder, "Applications", 490.0)] {
    let side = 112.0
    image.draw(in: CGRect(x: x - side / 2, y: titleBar + 120 - side / 2, width: side, height: side),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    text.draw(at: CGPoint(x: x - text.size().width / 2, y: titleBar + 120 + side / 2 + 4))
}

NSGraphicsContext.restoreGraphicsState()
rep.size = size
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("==> preview.swift: \(out.path(percentEncoded: false))")
