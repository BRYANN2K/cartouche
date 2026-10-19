// The console glyphs of the mockup, drawn as template images so the sidebar
// tints them like SF Symbols

import AppKit
import RetroArchKit
import SwiftUI

@MainActor
enum ConsoleGlyphImage {
    private static var cache: [ConsoleGlyph: NSImage] = [:]

    static func image(_ glyph: ConsoleGlyph) -> NSImage {
        if let hit = cache[glyph] { return hit }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            for path in paths(glyph) {
                path.lineWidth = 1.3
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.rawValue
        cache[glyph] = image
        return image
    }

    // 16 by 16, as launcher.html's SYS_GLYPH
    static func paths(_ glyph: ConsoleGlyph) -> [NSBezierPath] {
        func line(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
            return path
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        switch glyph {
        case .cartridge:
            return [rect(4, 2, 8, 10, 1.2), line([(6, 12), (6, 14), (10, 14), (10, 12)]), line([(6, 5), (10, 5)])]
        case .disc:
            return [circle(8, 8, 6), circle(8, 8, 1.6)]
        case .handheld:
            return [rect(4, 1.5, 8, 13, 1.8), rect(5.6, 3.2, 4.8, 4, 0.6), line([(6.4, 11), (8, 11)]),
                    line([(7.2, 10.2), (7.2, 11.8)]), circle(10, 11, 0.5)]
        }
    }
}

struct ConsoleGlyphView: View {
    let glyph: ConsoleGlyph

    var body: some View {
        Image(nsImage: ConsoleGlyphImage.image(glyph))
            .accessibilityHidden(true)
    }
}
