import AppKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Key screens compared with their references in Snapshots/ (see Snapshot.swift), English and French,
// light and dark. The in-game menu and the HUD draw dark whatever the Mac's appearance, so they
// are dark only. Fixtures and scratch folders only: no store, no Steam, no network.
@MainActor
@Suite("Screen snapshots", .serialized,
       .enabled(if: Snapshot.hostMatches, "a non-default accent colour or a non-English region changes the drawing"))
struct ScreenSnapshotTests {
    static let languages = ["en", "fr"]
    static let looks = [false, true]
    // 2026-11-05 21:30 UTC, the in-game clock's time
    static let clock = Date(timeIntervalSince1970: 1_793_914_200)

    private func each(_ name: String, looks: [Bool] = Self.looks,
                      _ draw: (String, Bool) async throws -> NSBitmapImageRep) async throws {
        let pinning = AppRefreshSnapshotTests()
        defer { pinning.unpin() }
        for language in Self.languages {
            pinning.pin(language)
            for dark in looks {
                try Snapshot.check(try await draw(language, dark), "\(name)-\(language)-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test("Library grid")
    func libraryGrid() async throws {
        try await each("library-grid") { language, dark in
            let scene = try await LibraryWindowTests.Scene("snap-library")
            defer { scene.fixture.remove() }
            await scene.model.load()
            return try await Snapshot.render(scene.window(.classic), size: CGSize(width: 1280, height: 720),
                                             dark: dark, language: language, settle: 0.8)
        }
    }

    @Test("Game panel: installed, not installed, running")
    func gamePanel() async throws {
        let fixture = try SteamFixture("snap-panel")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt(SteamFixture.apps.map(\.id))
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        for id in [367_520, 1_172_470, 730] { await compat.openGame(appID: id) }
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let actions = GameActionRunner(model: model, open: { _ in })
        let idle = ActivitySnapshotTests().center()
        let playing = ActivitySnapshotTests().center()
        playing.apply(SteamActivitySnapshot(runningAppID: 730))
        for (state, id, activity) in [("installed", "steam:367520", idle), ("not-installed", "steam:1172470", idle),
                                      ("running", "steam:730", playing)] {
            let game = try #require(model.game(id))
            try await each("game-panel-\(state)") { language, dark in
                let panel = GamePanel(game: game, model: model, compat: compat, actions: actions)
                    .environment(\.covers, fixture.covers())
                    .environment(\.activity, activity)
                    .environment(\.glassMode, .classic)
                    .background(Glass.window)
                return try await Snapshot.render(panel, size: CGSize(width: Glass.panelWidth, height: 900), dark: dark,
                                                 language: language)
            }
        }
    }

    @Test("Store page signed in")
    func storeSignedIn() async throws {
        try await each("store-ubisoft-signed-in") { language, dark in
            let scene = try await LibraryWindowTests.Scene("snap-store")
            defer { scene.fixture.remove() }
            await scene.model.load()
            let root = try scratchDirectory("snap-store")
            defer { try? FileManager.default.removeItem(at: root) }
            let folders = StoreFolders(root: root.appending(path: "stores"))
            let vault = MemoryVault()
            let files = StoreClientFiles(root: root.appending(path: "clients"), downloads: root.appending(path: "downloads"))
            let center = StoreCenter(folders: folders, vault: vault, files: files, library: scene.model)
            if let launcher = center.adapter(.ubisoft)?.officialLauncher {
                try FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data("MZ".utf8))
            }
            try vault.write(StoreSecret(account: "00000000-dead-beef-0000-000000000042", files: [:]), for: .ubisoft)
            try folders.saveLibrary([StoreGame(id: "720", title: "Harbor Lords"), StoreGame(id: "13504", title: "Far Shore"),
                                     StoreGame(id: "5595", title: "Far Cry 6"), StoreGame(id: "635", title: "Rayman Legends")],
                                    for: .ubisoft)
            await center.start(refresh: false)
            scene.model.selection = .source(.ubisoft)
            return try await Snapshot.render(scene.window(.classic).environment(center), size: CGSize(width: 1280, height: 620),
                                             dark: dark, language: language, settle: 0.8)
        }
    }

    @Test("Settings > Runners with an update offered")
    func runnersUpdate() async throws {
        let host = try RunnerUpdateModelTests()
        let (old, new) = try await host.builds()
        let model = host.model([old, new], calls: RunnerUpdateModelTests.Calls())
        await model.refresh()
        #expect(model.rows.first { $0.id == host.old }?.action == .update)
        try await each("settings-runners-update") { language, dark in
            try await Snapshot.render(Form { RunnersSection(model: model) }.formStyle(.grouped),
                                      size: CGSize(width: 640, height: 400), dark: dark, language: language)
        }
    }

    @Test("Background Apps window")
    func backgroundApps() async throws {
        let monitor = try await AppRefreshSnapshotTests.monitor(.normal, apps: "/nonexistent")
        defer { monitor.stopViewing() }
        let presenter = BackgroundAppsPresenter()
        presenter.show(.manual)
        try await each("background-apps") { language, dark in
            let view = BackgroundAppsView(monitor: monitor, presenter: presenter, maxHeight: 900)
                .frame(width: BackgroundAppsGrid.maxWidth)
                .background(Glass.window)
            return try await Snapshot.render(view, size: CGSize(width: BackgroundAppsGrid.maxWidth, height: 640), dark: dark,
                                             language: language)
        }
    }

    @Test("In-game menu, main tab")
    func overlayMenu() async throws {
        try await each("overlay-menu", looks: [true]) { language, _ in
            let c = OverlaySnapshotTests().center()
            OverlayText.use(language: language)
            c.live.sessionStart = Self.clock.addingTimeInterval(-72 * 60)
            return try await Snapshot.render(ZStack { StandInScene(); OverlayView(center: c, shown: true, nativeHUD: true) }
                                                .environment(\.overlayClock, Self.clock),
                                             size: CGSize(width: 1280, height: 800), dark: true, language: language, settle: 0.8)
        }
    }

    @Test("HUD Mini and Standard")
    func hud() async throws {
        for level in [HUDLevel.mini, .standard] {
            try await each("hud-\(level == .mini ? "mini" : "standard")", looks: [true]) { language, _ in
                let c = OverlaySnapshotTests().center()
                OverlayText.use(language: language)
                c.live.sessionStart = Self.clock.addingTimeInterval(-72 * 60)
                c.setOpen(false)
                c.set(.hud, level.rawValue)
                return try await Snapshot.render(ZStack { StandInScene(); OverlayView(center: c, shown: false, nativeHUD: true) }
                                                    .environment(\.overlayClock, Self.clock),
                                                 size: CGSize(width: 600, height: 420), dark: true, language: language, settle: 0.8)
            }
        }
    }
}
