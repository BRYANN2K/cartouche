// The last-resort cover for a Windows installer game: its exe's own icon,
// lifted by the payload's iconmaker helper, on a quiet gradient keyed off the
// game's name. Used only when no Steam art and no user cover exist.

import AppKit
import Foundation

enum PlaceholderCover {

    static func size(_ kind: ArtKind) -> CGSize {
        kind == .hero ? CGSize(width: 1920, height: 620) : CGSize(width: 600, height: 900)
    }

    // iconmaker <exe> <out.icns>: the game's own icon from the exe's PE
    // resources, squircle-masked, or nil when it has none or the helper is absent.
    static func icon(_ exe: URL, iconmaker: URL = SupportPaths.iconmaker, into folder: URL) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: iconmaker.path(percentEncoded: false)) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appending(path: Digest.sha256(of: Data(exe.path(percentEncoded: false).utf8)) + ".icns")
        guard let result = try? Shell.run(iconmaker.path(percentEncoded: false),
                                          [exe.path(percentEncoded: false), out.path(percentEncoded: false)]),
              result.succeeded,
              FileManager.default.fileExists(atPath: out.path(percentEncoded: false))
        else { return nil }
        return out
    }

    // A stable hue per game, so the placeholder keeps its color across launches.
    static func hue(_ name: String) -> CGFloat {
        let digest = Digest.sha256(of: Data(name.lowercased().utf8))
        return CGFloat(UInt64(digest.prefix(8), radix: 16) ?? 0) / 4_294_967_295
    }

    // The icon centered on a two-stop gradient; a cover, not a grey box.
    static func png(name: String, icon: NSImage, size: CGSize) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let rect = NSRect(origin: .zero, size: size)
        let top = hue(name)
        let bottom = (top + 0.07).truncatingRemainder(dividingBy: 1)
        NSGradient(colors: [
            NSColor(calibratedHue: top, saturation: 0.45, brightness: 0.40, alpha: 1),
            NSColor(calibratedHue: bottom, saturation: 0.55, brightness: 0.17, alpha: 1),
        ])?.draw(in: rect, angle: -90)

        let side = min(size.width, size.height) * 0.48
        let iconRect = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                              width: side, height: side)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = side * 0.09
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.035)
        shadow.set()
        icon.draw(in: iconRect)

        NSGraphicsContext.current?.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
