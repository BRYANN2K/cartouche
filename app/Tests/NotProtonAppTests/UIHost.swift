import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

// Draws a view as the window's backing store does, at a fixed scale so text
// and pixel reads stay the same whatever screen the test Mac's window is on
@MainActor
func renderedBitmap(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(view.bounds.width * scale),
                                     pixelsHigh: Int(view.bounds.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

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
        try #require(renderedBitmap(window.contentView!))
    }

    func texts(named name: String? = nil) throws -> [String] {
        let frame = window.contentView?.superview ?? window.contentView!
        let rep = try #require(renderedBitmap(frame))
        if let name, let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] {
            let dark = window.appearance?.name == .darkAqua
            let url = URL(filePath: folder).appending(path: "\(name)-\(dark ? "dark" : "light").png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        let image = try #require(rep.cgImage)
        return try recognizedTexts(in: image)
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
