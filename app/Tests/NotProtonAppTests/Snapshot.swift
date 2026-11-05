import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// Reference PNGs of key screens under Snapshots/, compared with a tolerance: a pixel differs when
// one channel moves more than `pixel` (of 255), and a shot fails past `ratio` differing pixels.
// CARTOUCHE_UPDATE_SNAPSHOTS=1 rewrites them. A failure leaves <name>.failed.png and <name>.diff.png
// beside the reference.
@MainActor
enum Snapshot {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Snapshots")

    static var updating: Bool { ProcessInfo.processInfo.environment["CARTOUCHE_UPDATE_SNAPSHOTS"] == "1" }

    struct Tolerance {
        var pixel: UInt8 = 24
        // An English label swapped for its French one moves about 2 % of a Settings form
        var ratio = 0.0025
    }

    // The references assume macOS's default accent (blue) and an English region, as on a fresh
    // hosted runner: AppKit reads the accent once at launch, and dates follow the region whatever
    // language the strings are pinned to. On another setup the comparison is skipped, not failed.
    nonisolated static var hostMatches: Bool {
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
            && Locale.current.language.languageCode?.identifier == "en"
    }

    // A borderless window that never shows: on the window server so lists load their rows,
    // drawn through AppKit at 1x, so glass draws flat and the result is the same headless
    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, language: String,
                                settle: Double = 0.5) async throws -> NSBitmapImageRep {
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.hoverEnabled, false)
            .transaction { $0.disablesAnimations = true }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        let end = Date().addingTimeInterval(settle)
        while Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        host.layoutSubtreeIfNeeded()
        return try #require(renderedBitmap(host, scale: 1), "the view did not draw")
    }

    static func check(_ rep: NSBitmapImageRep, _ name: String, tolerance: Tolerance = Tolerance(),
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = folder.appending(path: "\(name).png")
        let failed = folder.appending(path: "\(name).failed.png")
        let diffURL = folder.appending(path: "\(name).diff.png")
        for leftover in [failed, diffURL] { try? FileManager.default.removeItem(at: leftover) }
        let actual = try #require(Pixels(rep))
        if updating {
            try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(actual.png()).write(to: reference)
            return
        }
        guard let data = try? Data(contentsOf: reference), let stored = NSBitmapImageRep(data: data),
              let expected = Pixels(stored) else {
            try? actual.png()?.write(to: failed)
            Issue.record("No snapshot at Snapshots/\(name).png. Run with CARTOUCHE_UPDATE_SNAPSHOTS=1 to write it.",
                         sourceLocation: sourceLocation)
            return
        }
        guard expected.width == actual.width, expected.height == actual.height else {
            try? actual.png()?.write(to: failed)
            Issue.record("Snapshots/\(name).png is \(expected.width)x\(expected.height), the screen now draws \(actual.width)x\(actual.height)",
                         sourceLocation: sourceLocation)
            return
        }
        let (count, diff) = expected.compare(actual, pixel: tolerance.pixel)
        let ratio = Double(count) / Double(expected.width * expected.height)
        guard ratio > tolerance.ratio else { return }
        try? actual.png()?.write(to: failed)
        try? diff.png()?.write(to: diffURL)
        Issue.record(Comment(rawValue: String(format: "Snapshots/%@.png: %.2f%% of pixels differ (limit %.2f%%). See %@.diff.png and %@.failed.png; "
                            + "CARTOUCHE_UPDATE_SNAPSHOTS=1 rewrites the reference if the change is wanted.",
                            name, ratio * 100, tolerance.ratio * 100, name, name)), sourceLocation: sourceLocation)
    }

    // Straight RGBA8 in device RGB, whatever format the PNG decoder or the view handed back
    struct Pixels {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        init?(_ rep: NSBitmapImageRep) {
            guard let image = rep.cgImage else { return nil }
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            bytes = buffer
        }

        // The differing pixels in red over a faded copy of the reference
        func compare(_ other: Pixels, pixel: UInt8) -> (Int, Pixels) {
            var count = 0
            var out = [UInt8](repeating: 255, count: bytes.count)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                var worst: UInt8 = 0
                for c in 0..<4 {
                    let a = bytes[i + c], b = other.bytes[i + c]
                    worst = max(worst, a > b ? a - b : b - a)
                }
                if worst > pixel {
                    count += 1
                    out[i] = 255; out[i + 1] = 0; out[i + 2] = 0
                } else {
                    for c in 0..<3 { out[i + c] = UInt8(155 + Int(bytes[i + c]) * 100 / 255) }
                }
            }
            return (count, Pixels(width: width, height: height, bytes: out))
        }

        func png() -> Data? {
            var copy = bytes
            return copy.withUnsafeMutableBytes { raw -> Data? in
                var plane: UnsafeMutablePointer<UInt8>? = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: &plane, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)
                else { return nil }
                return rep.representation(using: .png, properties: [:])
            }
        }
    }
}
