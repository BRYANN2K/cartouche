import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// The panel's Your Play section and the Compare Setups sheet on the Elden Ring fixture,
// with sessions in a scratch store. PNGs go to CARTOUCHE_SNAPSHOTS when it is set.
@Suite("Your Play")
@MainActor
struct YourPlayTests {

    static let crossOver = Runner(
        id: "26.3.0.39832", kind: .crossOver, version: "26.3.0.39832", displayVersion: "26.3", flavors: [.rosetta],
        state: .ready, build: SupportedRunners.all.first, source: nil, isInstalled: true)

    @MainActor
    struct Scene {
        let fixture: SteamFixture
        let scratch = ScratchDefaults()
        let model: LibraryModel
        let compat: CompatibilityModel
        let performance: PerformanceModel
        let game: Game

        init(_ label: String, sessions: [StoredSession]) async throws {
            fixture = try SteamFixture(label)
            try fixture.writeExport()
            try fixture.addArt([1_245_620])
            model = libraryModel(fixture, defaults: scratch)
            compat = try fixtureCompat(fixture.root, defaults: scratch)
            let store = PerformanceStore(folder: fixture.root.appending(path: "performance"))
            for (i, session) in sessions.enumerated() { try store.add(session, folder: "fixture-\(i)") }
            performance = PerformanceModel(store: store, defaults: scratch.defaults)
            await model.load()
            model.runners = [YourPlayTests.crossOver]
            await performance.refresh()
            game = try #require(model.game("steam:1245620"))
        }

        var content: GamePanelContent {
            GamePanelContent(game: game, compat: compat.panel(appID: 1_245_620, method: .wine),
                             setup: model.setup(for: game.id), play: performance.play(appID: 1_245_620))
        }

        func renderPanel(_ name: String) async {
            for dark in [false, true] {
                let panel = GamePanel(game: game, model: model, compat: compat,
                                      actions: GameActionRunner(model: model, open: { _ in }))
                    .environment(performance)
                    .environment(\.covers, fixture.covers())
                await windowSnapshot(panel, named: name, size: CGSize(width: 360, height: 980), dark: dark, settle: 1)
            }
        }
    }

    static let dxmt = PlayStatsTests.dxmt
    static let d3dmetal = PlayStatsTests.d3dmetal
    static let dxvk = PlayStatsTests.dxvk

    static var threeSetups: [StoredSession] {
        [PlayStatsTests.session(0, setup: dxmt, name: "CrossOver 26.3 · DXMT", hours: 14.2, fps: 56, low: 41),
         PlayStatsTests.session(0, setup: d3dmetal, name: "CrossOver 26.3 · D3DMetal", hours: 1.1, fps: 34, low: 22, startedAt: 60_000),
         PlayStatsTests.session(0, setup: dxvk, name: "CrossOver 2026 08 21 FEX · DXVK", hours: 0.5, fps: 40, low: 31, startedAt: 70_000)]
    }

    @Test("The panel shows the average weighted by play time, the 1% low and the play time, after Play")
    func weightedInPanel() async throws {
        let scene = try await Scene("yourplay-weighted", sessions: Array(Self.threeSetups.prefix(2)))
        defer { scene.fixture.remove() }
        let content = scene.content
        #expect(content.sections.prefix(3) == [.play, .yourPlay, .expected])
        #expect(content.titles.contains("Your Play"))
        let play = try #require(content.play)
        #expect(YourPlayText.fps(play.average) == "54 fps")
        #expect(YourPlayText.fps(play.average) != "45 fps")
        #expect(YourPlayText.played(play.played) == "15 hr, 18 min")
        #expect(YourPlayRows.note(play) == nil)
        await scene.renderPanel("panel-your-play")
    }

    @Test("A game with no session has no Your Play section")
    func none() async throws {
        let scene = try await Scene("yourplay-none", sessions: [])
        defer { scene.fixture.remove() }
        #expect(scene.content.play == nil)
        #expect(!scene.content.sections.contains(.yourPlay))
    }

    @Test("Compare Setups lists each setup with average, 1% low and play time, marks the best, and offers to use it")
    func compare() async throws {
        let scene = try await Scene("yourplay-compare", sessions: Self.threeSetups)
        defer { scene.fixture.remove() }
        // The game runs DXVK now, so the best setup is not the one in use
        var choice = scene.model.setup(for: scene.game.id)
        choice.graphics = .dxvk
        scene.model.setSetup(choice, for: scene.game.id, tellSteam: false)
        let play = try #require(scene.performance.play(appID: 1_245_620))
        #expect(play.setups.count == 3)
        let rows = play.setups.map {
            "\(YourPlayText.runner($0)) | \(YourPlayText.detail($0.setup)) | \(YourPlayText.fps($0.average)) | \(YourPlayText.fps($0.low1)) | \(YourPlayText.played($0.played))"
        }
        #expect(rows == [
            "CrossOver 26.3 | DXMT, Rosetta | 56 fps | 41 fps | 14 hr, 12 min",
            "CrossOver 2026 08 21 FEX | DXVK, FEX | 40 fps | 31 fps | 30 min",
            "CrossOver 26.3 | D3DMetal, Rosetta | 34 fps | 22 fps | 1 hr, 6 min",
        ])
        let best = try #require(play.best)
        #expect(best.setup == Self.dxmt)
        #expect(YourPlayText.best(best, among: play.setups) == "DXMT")
        let current = scene.model.resolution(for: scene.game).setup
        #expect(!CompareSetupsSheet.matches(best.setup, current))

        for dark in [false, true] {
            let sheet = CompareSetupsSheet(game: scene.game, play: play, model: scene.model)
            await windowSnapshot(sheet, named: "compare-setups", size: CGSize(width: 640, height: 320), dark: dark)
        }
        await scene.renderPanel("panel-your-play-three-setups")

        // Use This Setup
        scene.model.setSetup(CompareSetupsSheet.choice(best.setup, from: scene.model.setup(for: scene.game.id),
                                                       macBuild: scene.model.hasMacBuild(scene.game)),
                             for: scene.game.id, tellSteam: false)
        let after = scene.model.resolution(for: scene.game).setup
        #expect(after.backend == .dxmt)
        #expect(CompareSetupsSheet.matches(best.setup, after))
    }

    @Test("A runner that refuses the counter: the panel says FPS can't be measured with this runner")
    func blocked() async throws {
        let refused = PlayStatsTests.session(0, setup: Self.dxvk, name: "CrossOver 2026 08 21 FEX · DXVK", hours: 2, fps: 0,
                                             startedAt: 80_000, measurement: .refused)
        let scene = try await Scene("yourplay-refused", sessions: [refused])
        defer { scene.fixture.remove() }
        let play = try #require(scene.content.play)
        #expect(play.measurementRefused)
        #expect(YourPlayRows.note(play) == "FPS can't be measured with this runner")
        #expect(YourPlayText.played(play.played) == "2 hr")
        #expect(scene.content.sections.contains(.yourPlay))
        await scene.renderPanel("panel-your-play-refused")
    }

    @Test("Sessions the run script leaves are read in when the panel refreshes")
    func refreshReadsIncoming() async throws {
        let fixture = try PerformanceFixture("model")
        defer { fixture.remove() }
        let start = PerformanceFixture.start
        try fixture.launch("1245620-a-1", ended: start + 400, seconds: 330, fps: 58)
        let scratch = ScratchDefaults()
        let model = PerformanceModel(store: fixture.store, defaults: scratch.defaults)
        await model.refresh()
        let play = try #require(model.play(appID: 1_245_620))
        #expect(play.average == 58)
        #expect(play.played == 400)
        #expect(model.play(appID: nil) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.incoming.path(percentEncoded: false)).isEmpty)
    }
}
