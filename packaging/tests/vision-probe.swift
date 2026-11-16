import AppKit
import Vision

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 120,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 120)).fill()
("Cartouche console test" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [
    .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black,
])
NSGraphicsContext.restoreGraphicsState()
for revision in [VNRecognizeTextRequestRevision1, VNRecognizeTextRequestRevision2, VNRecognizeTextRequestRevision3] {
    for cpu in [true, false] {
      for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
       for fromData in [false, true] {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.usesCPUOnly = cpu
        do {
            let handler = fromData ? VNImageRequestHandler(data: bitmap.representation(using: .png, properties: [:])!) : VNImageRequestHandler(cgImage: bitmap.cgImage!)
            try handler.perform([request])
            print("revision=\(revision) cpu=\(cpu) level=\(level.rawValue) data=\(fromData): \(request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])")
        } catch {
            let detail = error as NSError
            print("revision=\(revision) cpu=\(cpu) level=\(level.rawValue) data=\(fromData): \(detail.domain) \(detail.code) \(detail.userInfo)")
        }
    }
       }
      }
}
