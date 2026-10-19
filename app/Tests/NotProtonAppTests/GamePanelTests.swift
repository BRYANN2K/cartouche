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
        let compat = try fixtureCompat(fixture.root, defaults: scratch)
        await compat.openGame(appID: 1_245_620)
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        let game = try #require(model.game("steam:1245620"))
        let content = GamePanelContent(game: game, compat: compat.panel(appID: 1_245_620, method: .wine),
                                       setup: model.setup(for: game.id))
        return (content, compat, model, fixture)
    }

    @Test("Panel content: Play, Expected on This Mac, Anti-Cheat on Linux, Graphics Reported on Macs, Setup, in this order")
    func panelOrder() async throws {
        let (content, _, _, fixture) = try await eldenRing("panel")
        defer { fixture.remove() }
        #expect(content.titles == ["Play", "Expected on This Mac", "Anti-Cheat on Linux", "Graphics Reported on Macs", "Setup"])
        #expect(content.subtitle(now: Date()) == "Steam. Played yesterday.")

        let (estimate, line) = GamePanelContent.estimate(content.compat.estimate, macReportsOn: true)
        #expect(line == nil)
        #expect(estimate?.rating == "Good")
        #expect(content.compat.antiCheat?.level == .onlineWorks)
        #expect(content.compat.antiCheat?.title.hasPrefix("Online works on Linux") == true)
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
        #expect(!content.titles.contains("Sources"))
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

    @Test("A game with no reports and no anti-cheat shows only Play, Expected and Setup")
    func sparseGame() async throws {
        let (_, compat, _, fixture) = try await eldenRing("sparse")
        defer { fixture.remove() }
        let game = Game.steam(999_999, name: "Unknown", installed: false)
        let content = GamePanelContent(game: game, compat: compat.panel(appID: 999_999, method: .wine), setup: GameSetupChoice())
        #expect(content.titles == ["Install", "Expected on This Mac", "Setup"])
        #expect(GamePanelContent.estimate(content.compat.estimate, macReportsOn: true).1 == "No reports yet for this version")
    }

    @Test("Opening a game's panel asks MacGamingDB for that game")
    func panelOpensTheGame() async throws {
        let fixture = try SteamFixture("open")
        defer { fixture.remove() }
        try fixture.writeExport()
        try fixture.addArt([1_245_620])
        let scratch = ScratchDefaults()
        let compat = try fixtureCompat(fixture.root, defaults: scratch)
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
