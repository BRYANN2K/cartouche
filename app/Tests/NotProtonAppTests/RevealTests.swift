import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// A cover with color everywhere: a hue sweep with darker stripes, so gray and color
// are easy to tell apart pixel by pixel
func revealFixtureCover(width: Int = 300, height: Int = 450) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        let hue = CGFloat(x) / CGFloat(width)
        for band in 0..<9 {
            let brightness: CGFloat = band % 2 == 0 ? 0.85 : 0.6
            context.setFillColor(NSColor(hue: hue, saturation: 0.8, brightness: brightness, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: band * height / 9, width: 1, height: height / 9 + 1))
        }
    }
    return context.makeImage()!
}

// Per row, the share of pixels that carry color (channel spread over 0.15)
struct PixelRows {
    let width: Int
    let height: Int
    let colored: [Double]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows: [Double] = []
        // CGContext rows start at the top of the image in memory
        for y in 0..<height {
            var n = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                let c = [bytes[i], bytes[i + 1], bytes[i + 2]].map(Int.init)
                if c.max()! - c.min()! > 38 { n += 1 }
            }
            rows.append(Double(n) / Double(width))
        }
        colored = rows
    }

    // Rows from `from` to `to`, as fractions of the height from the top
    func share(_ from: Double, _ to: Double) -> Double {
        let a = Int(Double(height) * from), b = max(a + 1, Int(Double(height) * to))
        return colored[a..<b].reduce(0, +) / Double(b - a)
    }
}

func writePNG(_ image: CGImage, _ name: String) {
    guard let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] else { return }
    let url = URL(filePath: folder).appending(path: "\(name).png")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor
@Suite("Cover reveal", .serialized, .enabled(if: RevealRenderer.shared != nil, "this Mac has no Metal device"))
struct RevealTests {

    let cover = revealFixtureCover()

    func frame(_ progress: Float, time: Float = 1.3, finish: Float = 0, motion: Float = 1) throws -> CGImage {
        let renderer = try #require(RevealRenderer.shared)
        var u = RevealUniforms()
        u.progress = progress
        u.time = time
        u.finish = finish
        u.motion = motion
        return try #require(renderer.render(cover, width: 300, height: 450, uniforms: u))
    }

    @Test("The shader compiles from source with the Metal framework's own compiler")
    func compiles() {
        #expect(RevealRenderer.shared != nil)
        #expect(MemoryLayout<RevealUniforms>.stride == 48)
    }

    @Test("Progress drives the reveal: at 50% about the lower half is in color, the top stays gray")
    func halfway() throws {
        let rows = PixelRows(try frame(0.5))
        let whole = rows.share(0, 1)
        print("reveal at 50%: colored \(whole), top quarter \(rows.share(0, 0.25)), bottom quarter \(rows.share(0.75, 1))")
        #expect(whole > 0.4 && whole < 0.6, "colored share \(whole)")
        #expect(rows.share(0.75, 1) > 0.95, "bottom quarter \(rows.share(0.75, 1))")
        #expect(rows.share(0, 0.25) < 0.05, "top quarter \(rows.share(0, 0.25))")
        #expect(rows.share(0.5, 1) > rows.share(0, 0.5) * 3)
    }

    @Test("From black and white at 0% to full color at 100%, rising with progress")
    func rises() throws {
        let shares = try [0.0, 0.25, 0.5, 0.75, 1.0].map { PixelRows(try frame(Float($0))).share(0, 1) }
        print("reveal colored share at 0, 25, 50, 75, 100%: \(shares)")
        #expect(shares[0] < 0.03, "0%: \(shares[0])")
        #expect(shares[4] > 0.97, "100%: \(shares[4])")
        #expect(shares == shares.sorted(), "\(shares)")
    }

    @Test("The front moves with time while motion is on; the embers only draw with motion")
    func moves() throws {
        let a = try frame(0.5, time: 1), b = try frame(0.5, time: 2)
        #expect(a.dataProvider?.data as Data? != b.dataProvider?.data as Data?)
        let still1 = try frame(0.5, time: 0, motion: 0), still2 = try frame(0.5, time: 0, motion: 0)
        #expect(still1.dataProvider?.data as Data? == still2.dataProvider?.data as Data?)
    }

    @Test("Aspect-fill crop for covers of another shape")
    func crop() {
        #expect(RevealRenderer.crop(image: CGSize(width: 600, height: 900), target: CGSize(width: 200, height: 300)) == SIMD4(0, 0, 1, 1))
        let wide = RevealRenderer.crop(image: CGSize(width: 1200, height: 900), target: CGSize(width: 200, height: 300))
        #expect(abs(wide.z - 0.5) < 0.001 && abs(wide.x - 0.25) < 0.001)
    }

    @Test("Frame captures and a recorded run for the evidence")
    func captures() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] else { return }
        // Steam portrait art when the scratch cache has it, else the fixture cover
        var art = cover
        if let path = ProcessInfo.processInfo.environment["CARTOUCHE_REVEAL_COVER"],
           let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            art = image
        }
        let renderer = try #require(RevealRenderer.shared)
        func shot(_ p: Float, time: Float = 1.3, finish: Float = 0, motion: Float = 1) -> CGImage? {
            var u = RevealUniforms()
            u.progress = p
            u.time = time
            u.finish = finish
            u.motion = motion
            return renderer.render(art, width: 400, height: 600, uniforms: u)
        }
        for (p, name) in [(0.1, "10"), (0.34, "34"), (0.5, "50"), (0.9, "90")] {
            if let image = shot(Float(p)) { writePNG(image, "reveal-frame-\(name)") }
        }
        if let image = shot(1, finish: 0.55) { writePNG(image, "reveal-frame-finish") }

        // 6 seconds at 30 fps: the download from 5% to 100%, then the finish ring
        let url = URL(filePath: folder).appending(path: "reveal.mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 400, AVVideoHeightKey: 600,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 400,
            kCVPixelBufferHeightKey as String: 600,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 180
        var shown: Double = 0.05
        for i in 0..<frames {
            let t = Double(i) / 30
            let target = min(1, 0.05 + t / 4.5)
            shown += (target - shown) * 0.2
            let finishing = t > 4.8 ? Float(max(0, 1 - (t - 4.8) / 1.1)) : 0
            guard let image = shot(t > 4.8 ? 1 : Float(shown), time: Float(t), finish: finishing) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 400, height: 600, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 600))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}

@MainActor
@Suite("Cover reveal with Reduce Motion")
struct RevealStillTests {

    @Test("Reduce Motion: a still color and gray split, no moving edge, no embers")
    func reduceMotion() throws {
        #expect(!CoverReveal.usesShader(reduceMotion: true))
        let cover = NSImage(cgImage: revealFixtureCover(), size: NSSize(width: 300, height: 450))
        let gray = try #require(CoverImages.blackAndWhite(cover))
        func render(_ fraction: Double) throws -> CGImage {
            let renderer = ImageRenderer(content: StaticReveal(color: cover, gray: gray, fraction: fraction).frame(width: 300, height: 450))
            renderer.scale = 1
            return try #require(renderer.cgImage)
        }
        let half = try render(0.5)
        let rows = PixelRows(half)
        // A straight edge: every row above the middle is gray, every row below is in color
        #expect(rows.colored[0..<224].allSatisfy { $0 < 0.01 })
        #expect(rows.colored[226..<450].allSatisfy { $0 > 0.99 })
        // Nothing depends on time: two renders are the same
        #expect(try render(0.5).dataProvider?.data as Data? == half.dataProvider?.data as Data?)
        writePNG(half, "reveal-reduce-motion-50")
        let quarter = PixelRows(try render(0.25))
        #expect(abs(quarter.share(0, 1) - 0.25) < 0.01)
    }
}
