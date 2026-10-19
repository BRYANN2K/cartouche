import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// The activity slot, the panel's download block and a revealing cover, rendered
// offscreen in light and dark. PNGs go to CARTOUCHE_SNAPSHOTS when it is set.
// Offscreen captures draw no Metal layer, so covers use the still split here.
@MainActor
@Suite("Activity screens", .serialized)
struct ActivitySnapshotTests {

    func center(downloads: [DownloadActivity] = [], playing: RunningGame? = nil) -> ActivityCenter {
        let center = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                    notifier: RecordingActivityNotifier())
        center.apply(SteamActivitySnapshot(downloads: downloads))
        center.consoleGame = playing
        return center
    }

    @Test("The library with God of War downloading: the cover colors in from the bottom, the slot shows the ring")
    func library() async throws {
        let scene = try LibraryWindowTests.Scene("activity-window")
        defer { scene.fixture.remove() }
        await scene.model.load()
        let activity = center(downloads: [godOfWar])
        let gow = Game.steam(1_593_500, name: "God of War", installed: false)
        #expect(activity.reveal(for: gow)?.fraction == godOfWar.fraction)
        guard case .downloads = activity.slot else { Issue.record("no download slot"); return }
        // The window's parts, and as few windows as possible: each window with AppKit controls
        // rendered offscreen leaves an animation thread behind in a test process, and once 64
        // are stuck, DispatchQueue.global() runs nothing more
        let actions = GameActionRunner(model: scene.model, open: { _ in })
        guard case .grid(let sections) = scene.model.screen else { Issue.record("no grid"); return }
        // The grid with the sidebar, then God of War's panel in a window of the inspector's width
        let parts = HStack(spacing: 0) {
            LibrarySidebar(model: scene.model).activitySlot(activity, library: scene.model).frame(width: 230)
            Divider()
            LibraryGrid(model: scene.model, sections: sections, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1100, height: 800)
        let panel = GamePanel(game: gow, model: scene.model, compat: scene.compat, actions: actions)
        for dark in [false, true] {
            for (selected, name, view, size) in [
                ("steam:1245620", "library-downloading", AnyView(parts), CGSize(width: 1100, height: 800)),
                ("steam:1593500", "panel-downloading", AnyView(panel), CGSize(width: 360, height: 760)),
            ] {
                scene.model.select(selected)
                await windowSnapshot(view.environment(\.covers, scene.fixture.covers()).environment(\.activity, activity)
                                         .environment(\.revealStill, true),
                                     named: name, size: size, dark: dark, settle: 0.8)
            }
        }
    }

    @Test("Each state of the slot, and the sidebar with it")
    func slots() async throws {
        var paused = godOfWar
        paused.state = .paused
        var failed = godOfWar
        failed.state = .failed("Not enough disk space")
        let apex = DownloadActivity(appID: 1_172_470, name: "Apex Legends", state: .downloading, bytesDone: 30, bytesTotal: 100)
        let install = InstallActivity(title: "Disco Elysium", fraction: 0.42, stuck: false, waiting: 1)
        let stuck = InstallActivity(title: "Disco Elysium", fraction: 0.42, stuck: true, waiting: 0)
        let cards: [(String, AnyView)] = [
            ("slot-playing", AnyView(PlayingCard(game: eldenRing) {})),
            ("slot-playing-retroarch", AnyView(PlayingCard(game: RunningGame(id: "console:1", name: "Super Metroid", target: .console, fps: 60)) {})),
            ("slot-installing", AnyView(InstallingCard(install: install) {})),
            ("slot-installing-stuck", AnyView(InstallingCard(install: stuck) {})),
            ("slot-store", AnyView(StoreInstallCard(activity: epicDownload, stop: {}, show: {}))),
            ("slot-downloading", AnyView(DownloadsCard(summary: DownloadSummary(downloads: [godOfWar]), toggle: {}, show: {}))),
            ("slot-downloading-two", AnyView(DownloadsCard(summary: DownloadSummary(downloads: [godOfWar, apex]), toggle: {}, show: {}))),
            ("slot-paused", AnyView(DownloadsCard(summary: DownloadSummary(downloads: [paused]), toggle: {}, show: {}))),
            ("slot-failed", AnyView(DownloadsCard(summary: DownloadSummary(downloads: [failed]), toggle: {}, show: {}))),
            ("slot-update", AnyView(UpdateCard(update: UpdateActivity(id: "dxmt", title: "DXMT 0.80", kind: "Graphics")))),
            ("panel-download-block", AnyView(DownloadBlock(download: godOfWar, center: center(downloads: [godOfWar])))),
            ("panel-download-block-paused", AnyView(DownloadBlock(download: paused, center: center(downloads: [paused])))),
            ("panel-download-block-failed", AnyView(DownloadBlock(download: failed, center: center(downloads: [failed])))),
        ]
        for (name, view) in cards {
            for dark in [false, true] {
                let size = snapshot(view.frame(width: name.hasPrefix("panel") ? 320 : 200).groupBackground(radius: 12), named: name, dark: dark)
                #expect(size.width > 0)
            }
        }

        // The sidebar with the slot at the bottom, and without anything going on
        let scene = try LibraryWindowTests.Scene("activity-sidebar")
        defer { scene.fixture.remove() }
        await scene.model.load()
        for (name, activity) in [("sidebar-activity-playing", center(downloads: [godOfWar], playing: eldenRing)),
                                 ("sidebar-activity-hidden", center())] {
            for dark in [false, true] {
                await windowSnapshot(LibrarySidebar(model: scene.model).activitySlot(activity, library: scene.model),
                                     named: name, size: CGSize(width: 240, height: 640), dark: dark)
            }
        }
    }

    @Test("Showing a download from the slot selects the game and opens its panel")
    func showFromSlot() async throws {
        let scene = try LibraryWindowTests.Scene("activity-show")
        defer { scene.fixture.remove() }
        await scene.model.load()
        scene.model.selection = .favorites
        scene.model.showPanel = false
        scene.model.reveal(gameID: "steam:1593500")
        #expect(scene.model.selectedGameID == "steam:1593500")
        #expect(scene.model.selection == .source(.steam))
        #expect(scene.model.showPanel)
    }
}
