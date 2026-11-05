import CoreGraphics
import Foundation
import Testing
import Vision

// Reads the text drawn in an image. Vision's recognizer needs the Neural Engine or a real
// GPU, which a hosted CI runner (CARTOUCHE_CI_HOSTED=1) may lack: there a failure cancels
// the test with the reason instead of failing it. Off a hosted runner it fails as before.
func recognizedTexts(in image: CGImage) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch where ProcessInfo.processInfo.environment["CARTOUCHE_CI_HOSTED"] == "1" {
        let reason = "skipped: Vision text recognition cannot run on this hosted runner (\(error))"
        FileHandle.standardError.write(Data("\(reason)\n".utf8))
        try Test.cancel(Comment(rawValue: reason))
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}
