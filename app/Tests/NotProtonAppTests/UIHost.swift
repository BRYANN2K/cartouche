import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

// A view in an invisible window that a test drives through its AppKit
// controls and its model, then reads back as drawn text
@MainActor
final class UIHost {
    let window: NSWindow

    init<V: View>(_ view: V, size: CGSize, dark: Bool = false) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        window.setContentSize(size)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func settle(_ seconds: Double = 0.3) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // SwiftUI draws its buttons itself, but a segmented picker is an AppKit
    // NSSegmentedControl: this picks a segment as a click does, through its action
    @discardableResult
    func select(segment label: String) async -> Bool {
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl,
               (0..<control.segmentCount).contains(where: { control.label(forSegment: $0) == label }) { return control }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let root = window.contentView, let control = find(root),
              let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label })
        else { return false }
        control.selectedSegment = index
        let sent = control.sendAction(control.action, to: control.target)
        await settle()
        return sent
    }

    func bitmap() throws -> NSBitmapImageRep {
        let frame = window.contentView!
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep
    }

    func texts(named name: String? = nil) throws -> [String] {
        let frame = window.contentView?.superview ?? window.contentView!
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if let name, let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] {
            let dark = window.appearance?.name == .darkAqua
            let url = URL(filePath: folder).appending(path: "\(name)-\(dark ? "dark" : "light").png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        let image = try #require(rep.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    // Waits until the drawn text shows this, up to a limit
    func wait(for text: String, within limit: Duration = .seconds(5)) async throws -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if seen(try texts(), text) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func close() {
        window.contentViewController = nil
        window.orderOut(nil)
        window.close()
    }
}
