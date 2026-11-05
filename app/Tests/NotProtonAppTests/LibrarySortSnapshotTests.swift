import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Evidence PNGs of the sort ball at 2x, English and French, light and dark.
// Runs only with CARTOUCHE_LIBRARY_SORT_SNAPSHOTS=<folder>. The window stays invisible; nothing reads the screen.
@MainActor
@Suite("Library sort snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_LIBRARY_SORT_SNAPSHOTS"] != nil))
struct LibrarySortSnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_LIBRARY_SORT_SNAPSHOTS"] ?? "/tmp")

    struct Shot {
        let name: String
        var width: CGFloat = 1280
        var scrolled = false
        var mode = GlassMode.liquid
        var languages = ["en", "fr"]
        var after: (@MainActor (LibraryModel) -> Void)?
        let prepare: @MainActor (LibraryModel) -> Void
    }

    static let shots: [Shot] = [
        Shot(name: "all-name") { _ in },
        Shot(name: "all-name-scrolled", scrolled: true) { _ in },
        Shot(name: "all-material", mode: .classic) { _ in },
        Shot(name: "all-material-scrolled", scrolled: true, mode: .classic) {
            $0.installedOnly = true
        },
        Shot(name: "narrow-longest", width: 800, languages: ["it", "zh-Hans"], after: { $0.select("steam:730") }) {
            $0.sort = .lastPlayed
            $0.installedOnly = true
        },
        Shot(name: "source-lastplayed") {
            $0.selection = .source(.steam)
            $0.sort = .lastPlayed
        },
        Shot(name: "all-playtime-installed") {
            $0.sort = .playTime
            $0.installedOnly = true
        },
        Shot(name: "empty") {
            $0.selection = .source(.gog)
            $0.installedOnly = true
        },
        Shot(name: "search-none") {
            $0.installedOnly = true
            $0.searchText = "Apex"
        },
        Shot(name: "narrow", width: 800) {
            $0.sort = .lastPlayed
            $0.installedOnly = true
        },
        Shot(name: "narrow-floating", width: 800, after: { $0.select("steam:730") }) {
            $0.sort = .lastPlayed
            $0.installedOnly = true
        },
        Shot(name: "narrow-nosidebar", width: 800) {
            $0.showSidebar = false
            $0.sort = .playTime
        },
        Shot(name: "ubisoft-lock") {
            $0.selection = .source(.ubisoft)
        },
        Shot(name: "store-ball", width: 800) {
            $0.selection = .source(.epic)
            $0.installedOnly = true
        },
        Shot(name: "wide-docked", width: 1720) {
            $0.sort = .lastPlayed
            $0.select("steam:1245620")
        },
    ]

    @Test func render() async throws {
        let pinning = AppRefreshSnapshotTests()
        defer { pinning.unpin() }
        for language in ["en", "fr", "it", "zh-Hans"] {
            pinning.pin(language)
            for dark in [false, true] {
                for shot in Self.shots where shot.languages.contains(language) {
                    let scene = try await LibraryWindowTests.Scene("sort-shots")
                    defer { scene.fixture.remove() }
                    await scene.model.load()
                    scene.model.stores = [.epic: .connected(account: "player42"), .gog: .connected(account: "player42"),
                                          .ubisoft: .connected(account: "player42")]
                    scene.model.otherGames = [
                        LibrarySortTests.game("The Witcher 3: Wild Hunt", .gog, installed: false),
                        LibrarySortTests.game("Baldur’s Gate II", .gog, installed: false),
                        LibrarySortTests.game("Fortnite", .epic),
                        LibrarySortTests.game("Alan Wake 2", .epic, installed: false),
                        LibrarySortTests.game("Ubisoft game 4865", .ubisoft, installed: false),
                        LibrarySortTests.game("Ubisoft game 720", .ubisoft),
                    ]
                    shot.prepare(scene.model)
                    try await capture(scene, shot, named: "\(shot.name)-\(language)-\(dark ? "dark" : "light")", dark: dark)
                }
            }
        }
    }

    // Liquid Glass only draws on the window server: the controls alone, in a panel of its own on the built-in display
    @Test func glass() async throws {
        let scene = try await LibraryWindowTests.Scene("sort-glass")
        defer { scene.fixture.remove() }
        await scene.model.load()
        let pinning = AppRefreshSnapshotTests()
        for dark in [false, true] {
            for on in [false, true] {
                scene.model.installedOnly = on
                let strip = ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(SteamFixture.apps.enumerated()), id: \.offset) { index, _ in
                            Color(hue: Double(index) / 8, saturation: 0.6, brightness: dark ? 0.5 : 0.8)
                        }
                    }
                    HStack(spacing: 12) { LibraryToolbarControls(model: scene.model) }
                        .padding(4)
                }
                .frame(width: 420, height: 40)
                try await pinning.capture(strip, dark: dark, to: folder.appending(path: "glass-\(on ? "on" : "off")-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func capture(_ scene: LibraryWindowTests.Scene, _ shot: Shot, named name: String, dark: Bool) async throws {
        let size = CGSize(width: shot.width, height: 720)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: scene.window(shot.mode))
        window.setContentSize(size)
        if let builtin = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }) { window.setFrameOrigin(builtin.visibleFrame.origin) }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentViewController = nil }
        try await Task.sleep(for: .seconds(0.5))
        if let after = shot.after {
            after(scene.model)
            try await Task.sleep(for: .seconds(0.5))
        }
        let frame = try #require(window.contentView?.superview ?? window.contentView)
        if shot.scrolled, let scroll = Self.scrollView(in: frame) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 220))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .seconds(0.4))
        }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width * 2),
                                                pixelsHigh: Int(frame.bounds.height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = frame.bounds.size
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > scroll.bounds.height { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
}
