import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Evidence PNGs of the launcher store's states in the whole window, at 2x. Runs only with
// CARTOUCHE_STORES_UI_SNAPSHOTS=<folder>. The window stays invisible and nothing reads the
// screen, so .glassEffect surfaces are missing from these: their layout shows, their glass doesn't.
@MainActor
@Suite("Launcher store snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_STORES_UI_SNAPSHOTS"] != nil))
struct StoreLauncherSnapshotTests {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_STORES_UI_SNAPSHOTS"] ?? "/tmp")

    struct Shot {
        let name: String
        var language = "en"
        var dark = false
        var width: CGFloat = 1280
        var signedIn = false
        var settings = false
        var mode = GlassMode.liquid
        var store = GameSource.ubisoft
        var prepare: @MainActor (StoreCenter) -> Void = { _ in }
    }

    static let shots: [Shot] = [
        Shot(name: "not-installed-en-light"),
        Shot(name: "downloading-fr-dark", language: "fr", dark: true, width: 800) { $0.launcherActivity[.ubisoft] = .downloading(0.42) },
        Shot(name: "installing-en-dark", dark: true) { $0.launcherActivity[.ubisoft] = .installing },
        Shot(name: "sign-in-fr-light", language: "fr", width: 800) { Self.ready($0) },
        Shot(name: "waiting-en-dark", dark: true, width: 800) {
            Self.ready($0)
            $0.signIn = SignInSession(store: .ubisoft, state: .preparing)
        },
        Shot(name: "start-failed-fr-light", language: "fr") {
            Self.ready($0)
            $0.launcherActivity[.ubisoft] = .startFailed(String(localized: "\(GameSource.ubisoft.name) closed right after it started."))
        },
        Shot(name: "grid-en-light", signedIn: true),
        Shot(name: "grid-fr-dark", language: "fr", dark: true, width: 800, signedIn: true),
        Shot(name: "accounts-fr-dark", language: "fr", dark: true, settings: true),
        Shot(name: "ea-not-installed-en-light", store: .ea),
        Shot(name: "ea-sign-in-fr-dark", language: "fr", dark: true, width: 800, store: .ea) { Self.ready($0, .ea) },
        Shot(name: "ea-port-fr-light", language: "fr", store: .ea) {
            Self.ready($0, .ea)
            $0.launcherActivity[.ea] = .startFailed(String(localized: "The EA app needs port 3216, already used by \("Spotify"). Quit it and try again."))
        },
        Shot(name: "ea-no-token-en-dark", dark: true, width: 800, store: .ea) {
            Self.ready($0, .ea)
            $0.signIn = SignInSession(store: .ea, state: .failed(String(localized: "EA signed you in, but its token did not reach Cartouche. Try again.")))
        },
        Shot(name: "ea-sidebar-en-light-classic", mode: .classic, store: .ea) { Self.ready($0, .ea) },
        Shot(name: "ea-sidebar-fr-dark-classic", language: "fr", dark: true, width: 800, mode: .classic, store: .ea) { Self.ready($0, .ea) },
        Shot(name: "ea-grid-en-dark-classic", dark: true, signedIn: true, mode: .classic, store: .ea),
        Shot(name: "ea-accounts-en-light", settings: true, store: .ea),
        Shot(name: "extra-grid-fr-dark-classic", language: "fr", dark: true, width: 800, signedIn: true, mode: .classic),
        Shot(name: "extra-grid-en-light-classic", signedIn: true, mode: .classic),
        Shot(name: "extra-grid-it-light", language: "it", width: 800, signedIn: true),
        Shot(name: "extra-failed-zh-dark", language: "zh-Hans", dark: true, width: 800) {
            Self.ready($0)
            $0.launcherActivity[.ubisoft] = .installFailed(String(localized: "The \(GameSource.ubisoft.name) installer did not finish. Open it again to check."))
        },
        Shot(name: "extra-narrow-grid-en-dark", dark: true, width: 640, signedIn: true),
        Shot(name: "extra-sign-in-en-light", width: 640) { Self.ready($0) },
    ]

    private static func ready(_ center: StoreCenter, _ store: GameSource = .ubisoft) {
        guard let launcher = center.adapter(store)?.officialLauncher else { return }
        try? FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data("MZ".utf8))
    }

    @Test func render() async throws {
        let pinning = AppRefreshSnapshotTests()
        defer { pinning.unpin() }
        for shot in Self.shots {
            pinning.pin(shot.language)
            let scene = try await LibraryWindowTests.Scene("stores-ui")
            defer { scene.fixture.remove() }
            await scene.model.load()
            let root = try scratchDirectory("stores-ui")
            defer { try? FileManager.default.removeItem(at: root) }
            let folders = StoreFolders(root: root.appending(path: "stores"))
            let vault = MemoryVault()
            let files = StoreClientFiles(root: root.appending(path: "clients"), downloads: root.appending(path: "downloads"))
            let center = StoreCenter(folders: folders, vault: vault, files: files, library: scene.model)
            if shot.signedIn || shot.settings {
                Self.ready(center, shot.store)
                try vault.write(StoreSecret(account: shot.store == .ea ? "Player One" : "00000000-dead-beef-0000-000000000042", files: [:]),
                                for: shot.store)
                try folders.saveLibrary([StoreGame(id: "720", title: "Harbor Lords"), StoreGame(id: "13504", title: "Far Shore"),
                                         StoreGame(id: "5595", title: "Far Cry 6"), StoreGame(id: "635", title: "Rayman Legends")],
                                        for: shot.store)
            }
            await center.start(refresh: false)
            scene.model.selection = .source(shot.store)
            shot.prepare(center)
            if shot.settings {
                try await capture(AccountsSettingsView(model: scene.model).environment(center),
                                  size: CGSize(width: 640, height: 420), shot)
            } else {
                try await capture(scene.window(shot.mode).environment(center), size: CGSize(width: shot.width, height: 620), shot)
            }
        }
    }

    // Liquid Glass only draws on the window server: a brief panel on the built-in display.
    @Test func glass() async throws {
        let pinning = AppRefreshSnapshotTests()
        let scene = try await LibraryWindowTests.Scene("stores-ui-glass")
        defer { scene.fixture.remove() }
        await scene.model.load()
        let root = try scratchDirectory("stores-ui-glass")
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = StoreFolders(root: root.appending(path: "stores"))
        let files = StoreClientFiles(root: root.appending(path: "clients"), downloads: root.appending(path: "downloads"))
        let center = StoreCenter(folders: folders, vault: MemoryVault(), files: files, library: scene.model)
        await center.start(refresh: false)
        Self.ready(center, .ea)
        scene.model.selection = .source(.ea)
        try await pinning.capture(scene.window(.liquid).environment(center).frame(width: 1100, height: 620), dark: false,
                                  to: folder.appending(path: "ea-glass-en-light.png"))
    }

    private func capture<V: View>(_ view: V, size: CGSize, _ shot: Shot) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, shot.dark ? .dark : .light))
        window.setContentSize(size)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentViewController = nil }
        try await Task.sleep(for: .seconds(0.6))
        let frame = try #require(window.contentView?.superview ?? window.contentView)
        let rep = try #require(renderedBitmap(frame))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(shot.name).png"))
    }
}
