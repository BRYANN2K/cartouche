import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Game panel")
@MainActor
struct GamePanelTests {

    private func eldenRing(_ label: String) async throws -> (GamePanelContent, CompatibilityModel, LibraryModel, SteamFixture) {
        let fixture = try SteamFixture(label)
        try fixture.writeExport()
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        await compat.openGame(appID: 1_245_620)
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let game = try #require(model.game("steam:1245620"))
        let content = GamePanelContent(game: game, compat: compat.panel(appID: 1_245_620, method: .wine),
                                       setup: model.setup(for: game.id))
        return (content, compat, model, fixture)
    }

    @Test("Game size distinguishes the Steam depot estimate from measured installed bytes")
    func gameSize() {
        var game = Game.steam(1, name: "Game", installed: false)
        game.storageBytes = 22_500_000_000
        game.storageEstimated = true
        let compat = CompatibilityPanel(record: nil, mac: nil, method: .wine, chip: "M4", data: nil, ageNotice: nil)
        let estimated = GamePanelContent(game: game, compat: compat, setup: GameSetupChoice())
        #expect(estimated.storageLine?.contains("22.5") == true || estimated.storageLine?.contains("22,5") == true)
        #expect(estimated.storageLine?.hasPrefix("Base game:") == true)
        #expect(estimated.metadataLine().contains(" · ≈ "))
        #expect(!estimated.metadataLine().contains("\n"))
        game.storageEstimated = false
        #expect(GamePanelContent(game: game, compat: compat, setup: GameSetupChoice()).storageLine?.hasSuffix("GB on disk") == true)
    }

    @Test("Installed games show Setup, then Your Play, then reports")
    func panelOrder() async throws {
        let (content, _, _, fixture) = try await eldenRing("panel")
        defer { fixture.remove() }
        #expect(content.sections == [.play, .setup, .yourPlay, .expected, .antiCheat, .graphics, .controls])
        #expect(content.playLabel == "Play")
        #expect(content.subtitle(now: fixture.now) == "Steam. Played yesterday.")

        let (estimate, line) = GamePanelContent.estimate(content.compat.estimate, macReportsOn: true)
        #expect(line == nil)
        #expect(estimate?.rating == "Good")
        #expect(content.compat.antiCheat?.level == .blocked)
        #expect(content.compat.antiCheat?.title == "Anti-cheat is not compatible with Wine")
        // One report each for DXMT and DXVK: a tie keeps the fixed order
        #expect(content.layers.map(\.layer) == [.d3dmetal, .dxmt, .dxvk])
        #expect(content.layers.first?.count == 21)
        #expect(content.bestLayer == .d3dmetal)
        // D3DMetal is the default and the most reported, so no suggestion
        #expect(content.suggestedBackend == nil)
    }

    @Test("Panel content: the Details sheet holds AppleGamingWiki, the Mac picker, the HUD and the sources")
    func detailsSheet() async throws {
        let (content, compat, _, fixture) = try await eldenRing("details")
        defer { fixture.remove() }
        #expect(content.detailsSections == [.expected, .macPicker, .allReports, .appleGamingWiki, .antiCheat, .advanced, .sources])
        #expect(content.detailsSections.map(\.title).contains("AppleGamingWiki"))
        #expect(content.compat.wiki?.ratings.isEmpty == false)
        #expect(GamePanelContent.wikiRows(["wine": "perfect", "crossover": "playable", "native": "na"]).map { "\($0.0): \($0.1)" }
            == ["Native: Not available", "CrossOver: Playable", "Wine: Perfect"])
        #expect(content.compat.sourcesLine?.contains("AppleGamingWiki (CC BY-NC-SA 3.0)") == true)
        #expect(content.compat.sourcesLine?.contains("MacGamingDB") == true)
        // The panel itself names no source
        #expect(!content.sections.map(\.title).contains("Sources"))
        #expect((compat.data?.gpuStrength.keys.count ?? 0) > 5)
    }

    @Test("A setup that differs from what most players use gets a suggestion")
    func suggestion() async throws {
        let (content, compat, model, fixture) = try await eldenRing("suggest")
        defer { fixture.remove() }
        var setup = content.setup
        setup.graphics = .dxmt
        model.setSetup(setup, for: content.game.id)
        let changed = GamePanelContent(game: content.game, compat: compat.panel(appID: 1_245_620, method: .wine),
                                       setup: model.setup(for: content.game.id))
        #expect(changed.suggestedBackend == .d3dmetal)
    }

    @Test("An uninstalled game hides Setup")
    func sparseGame() async throws {
        let (_, compat, _, fixture) = try await eldenRing("sparse")
        defer { fixture.remove() }
        let game = Game.steam(999_999, name: "Unknown", installed: false)
        let content = GamePanelContent(game: game, compat: compat.panel(appID: 999_999, method: .wine), setup: GameSetupChoice())
        #expect(content.sections == [.play, .expected, .controls])
        #expect(content.playLabel == "Install")
        #expect(GamePanelContent.estimate(content.compat.estimate, macReportsOn: true).1 == "No reports yet for this version")
    }

    @Test("Modules keep one order: Setup before Your Play, Continue From only when a console has a save")
    func moduleOrder() {
        #expect(PanelModules.list(.pc(installed: true, hasAntiCheat: true, hasGraphics: true, hasAdvanced: true))
            == [.play, .setup, .yourPlay, .expected, .antiCheat, .graphics, .advanced, .controls])
        #expect(PanelModules.list(.pc(installed: false, hasAntiCheat: false, hasGraphics: false, hasAdvanced: false))
            == [.play, .expected, .controls])
        let saved = PanelModules.list(.console(retroArch: true, biosMissing: false, hasStates: true))
        #expect(saved == [.play, .setup, .yourPlay, .continueFrom, .controls, .playTogether, .more])
        let fresh = PanelModules.list(.console(retroArch: true, biosMissing: false, hasStates: false))
        #expect(!fresh.contains(.continueFrom))
        #expect(fresh.firstIndex(of: .setup)! < fresh.firstIndex(of: .yourPlay)!)
        #expect(PanelModules.list(.console(retroArch: true, biosMissing: true, hasStates: false)).prefix(3)
            == [.play, .bios, .setup])
        #expect(PanelModules.list(.console(retroArch: false, biosMissing: true, hasStates: true))
            == [.play, .setup, .yourPlay, .controls, .more])
    }

    @Test("Opening a game's panel asks MacGamingDB for that game")
    func panelOpensTheGame() async throws {
        let fixture = try SteamFixture("open")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt([1_245_620])
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let game = try #require(model.game("steam:1245620"))
        #expect(compat.macReports[1_245_620] == nil)
        let panel = GamePanel(game: game, model: model, compat: compat, actions: GameActionRunner(model: model, open: { _ in }))
            .environment(\.covers, fixture.covers())
            .frame(width: 360, height: 900)
        await windowSnapshot(panel, named: "panel-elden-ring", size: CGSize(width: 360, height: 900), settle: 1)
        #expect(compat.macReports[1_245_620]?.rating == .veryGood)
    }

    @Test("The panel and the Details sheet render on the Elden Ring fixture, light and dark")
    func renders() async throws {
        let (content, compat, model, fixture) = try await eldenRing("render")
        defer { fixture.remove() }
        try fixture.addArt([1_245_620])
        for dark in [false, true] {
            let panel = GamePanel(game: content.game, model: model, compat: compat, actions: GameActionRunner(model: model, open: { _ in }))
                .environment(\.covers, fixture.covers())
            await windowSnapshot(panel, named: "panel-elden-ring", size: CGSize(width: 360, height: 980), dark: dark)
            let details = GameDetailsSheet(content: content, compat: compat, model: model, height: 1240)
            let size = snapshot(details, named: "details-elden-ring", dark: dark)
            #expect(size.width >= 560)
        }
    }
}

@Suite("Game panel widths", .serialized)
@MainActor
struct GamePanelWidthTests {

    @Test("At 300, 340 and 400 pt nothing is cut: title, Play and the Setup rows are all drawn whole")
    func widths() async throws {
        let fixture = try SteamFixture("panel-widths")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt(SteamFixture.apps.map(\.id))
        let scratch = ScratchDefaults()
        let compat = try await fixtureCompat(fixture.root, defaults: scratch)
        await compat.openGame(appID: 1_245_620)
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let game = try #require(model.game("steam:1245620"))
        let build = try #require(RunnerManifest.current().builds.first { $0.origin == .cartouche })
        model.runners = [Runner(id: build.id, kind: .wineBuild, version: build.version,
                                displayVersion: build.displayVersion, flavors: [.rosetta], state: .ready,
                                build: nil, source: nil, isInstalled: true)]
        for width in [300.0, 340, 400] {
            let panel = GamePanel(game: game, model: model, compat: compat,
                                  actions: GameActionRunner(model: model, open: { _ in }))
                .environment(\.covers, fixture.covers())
                .environment(\.glassMode, .classic)
                .frame(width: width, height: 900)
            let texts = try await renderedTexts(panel, size: CGSize(width: width, height: 900),
                                                named: "panel-\(Int(width))", dark: true, settle: 0.8)
            #expect(seen(texts, "Elden Ring"), "title cut at \(width): \(texts)")
            #expect(seen(texts, "Play"), "Play cut at \(width): \(texts)")
            #expect(seen(texts, "Runner"), "Setup cut at \(width): \(texts)")
            #expect(seen(texts, "Graphics"), "Graphics label cut at \(width): \(texts)")
        }
    }
}
