import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import NotProtonApp

// Evidence PNGs of each What's New page, French and English, light and dark. Runs only with
// CARTOUCHE_WHATSNEW_SNAPSHOTS=<folder>. The panel is ours alone: built-in display, non-activating,
// ignoring the mouse, captured by itself (never the screen).
@MainActor
@Suite("What's New snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_WHATSNEW_SNAPSHOTS"] != nil))
struct WhatsNewSnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_WHATSNEW_SNAPSHOTS"] ?? "/tmp")

    @Test func pages() async throws {
        let release = try #require(WhatsNewCatalog.release(for: "0.2.0-beta1"))
        for language in ["fr", "en"] {
            WhatsNewText.use(language: language)
            for dark in [false, true] {
                for page in release.pages.indices {
                    let name = "page-\(page + 1)-\(language)-\(dark ? "dark" : "light")"
                    try await capture(WhatsNewView(release: release, start: page) {}, dark: dark, to: folder.appending(path: "\(name).png"))
                }
            }
        }
    }

    func capture<V: View>(_ view: V, dark: Bool, to url: URL) async throws {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        let builtin = try #require(screen, "no built-in display")
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let card = view
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .clipShape(shape)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: card)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: builtin.frame.origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = host
        panel.setFrame(CGRect(origin: builtin.frame.origin, size: size), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .seconds(0.8))
        let rep: NSBitmapImageRep
        if let image = try? await windowImage(panel, size: size, scale: builtin.backingScaleFactor) {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            // Without Screen Recording: AppKit's own drawing of the view, glass drawn flat
            rep = try #require(renderedBitmap(host))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func windowImage(_ panel: NSPanel, size: CGSize, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let window = try #require(content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                          configuration: config)
    }
}
