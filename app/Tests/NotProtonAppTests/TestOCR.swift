import AppKit
import Foundation
import Vision

// The accurate Vision model is unavailable on hosted Mac VMs. Tesseract is a
// test-only dependency there; native runs can still use Vision without it.
func testOCR(_ image: CGImage) throws -> [String] {
    let binary = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    if let binary {
        let folder = URL.temporaryDirectory.appending(path: "cartouche-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "capture.png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: file)
        func read(_ extra: [String], pageSegmentation: String = "11") throws -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [file.path, "stdout", "--psm", pageSegmentation, "--dpi", "144", "-l", "eng"] + extra
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "TestOCR", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Tesseract did not finish successfully"])
            }
            return String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        }
        var texts = try read([])
        // Local thresholding also retains the pale labels of disabled controls.
        texts = mergeOCR(texts, try read(["-c", "thresholding_method=2", "-c", "thresholding_kfactor=0.05"]))
        // Sparse-page OCR can miss text on filled buttons. Vision's fast
        // reader sees those; merge by maximum occurrence count so two readers
        // cannot make one control look like two controls.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        if (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil {
            texts = mergeOCR(texts, (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }
        // Block segmentation retains disabled filled-button labels. It also
        // joins neighboring controls into lines; exclude lines containing a
        // control already read so they cannot inflate occurrence assertions.
        let block = try read([], pageSegmentation: "6").filter { candidate in
            !texts.contains { $0 != candidate && $0.count >= 5 && candidate.contains($0) }
        }
        return mergeOCR(texts, block)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.usesCPUOnly = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

private func mergeOCR(_ primary: [String], _ alternate: [String]) -> [String] {
    let counts = Dictionary(grouping: primary, by: { $0 }).mapValues(\.count)
    var seen: [String: Int] = [:]
    var result = primary
    for text in alternate {
        seen[text, default: 0] += 1
        if seen[text, default: 0] > counts[text, default: 0] { result.append(text) }
    }
    return result
}
