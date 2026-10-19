import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// What the Graphics menu and the panel's Setup rows offer, on the fixture Steam library.
// Runners are built in memory; screenshots go to CARTOUCHE_SNAPSHOTS when it is set.
@Suite("Setup menus offer valid pairs only")
@MainActor
struct SetupMenuTests {

    func model(_ label: String, runners: [Runner], availability: BackendAvailability, macBuilds: Set<Int> = [])
        async throws -> (LibraryModel, SteamFixture, ScratchDefaults) {
        let fixture = try SteamFixture(label)
        try fixture.writeExport()
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, defaults: scratch)
        await model.load()
        model.runners = runners
        model.backendAvailability = availability
        model.macBuilds = macBuilds
        return (model, fixture, scratch)
    }

    func graphicsTitles(_ game: Game, _ model: LibraryModel) -> [String] {
        GameMenu.items(for: game, in: model).first { $0.title == "Graphics" }?.children.map(\.title) ?? []
    }

    @Test("On a runner without D3DMetal the Graphics menu leaves it out; with it, D3DMetal comes first")
    func graphicsMenu() async throws {
        let (model, fixture, _) = try await model("setup-menu", runners: [GameSetupTests.release], availability: BackendAvailability())
        defer { fixture.remove() }
        let elden = try #require(model.game("steam:1245620"))
        #expect(graphicsTitles(elden, model) == ["DXMT", "DXVK", "wined3d"])
        #expect(model.graphicsChoices(for: elden) == [.dxmt, .dxvk, .wined3d])

        model.backendAvailability = BackendAvailability(d3dMetalRunners: [GameSetupTests.release.id])
        #expect(graphicsTitles(elden, model) == ["D3DMetal", "DXMT", "DXVK", "wined3d"])
        let checked = GameMenu.items(for: elden, in: model).first { $0.title == "Graphics" }?.children.first(where: \.checked)
        #expect(checked?.title == "D3DMetal")
    }

    @Test("FEX is offered only by a runner that serves it, so never on macOS 15")
    func translation() async throws {
        let sequoia = GameSetupTests.crossOver("27.0.0.41073-fex", fexAvailable: false)
        let (model, fixture, _) = try await model("setup-fex", runners: [sequoia], availability: BackendAvailability())
        defer { fixture.remove() }
        let elden = try #require(model.game("steam:1245620"))
        #expect(model.translationChoices(for: elden) == [.rosetta])
        model.runners = [GameSetupTests.fexBuild]
        #expect(model.translationChoices(for: elden) == [.rosetta, .fex])
        var choice = model.setup(for: elden.id)
        choice.translation = .fex
        model.setSetup(choice, for: elden.id)
        #expect(!model.graphicsChoices(for: elden).contains(.d3dmetal))
    }

    @Test("For the Mac version there is no runner or backend to pick")
    func macVersion() async throws {
        let (model, fixture, _) = try await model("setup-mac", runners: [GameSetupTests.release], availability: BackendAvailability(),
                                                  macBuilds: [1_091_500])
        defer { fixture.remove() }
        let cyberpunk = try #require(model.game("steam:1091500"))
        let items = GameMenu.items(for: cyberpunk, in: model)
        #expect(items.first { $0.title == "Graphics" }?.disabled == true)
        #expect(items.first { $0.title == "Runner" }?.disabled == true)
        var choice = model.setup(for: cyberpunk.id)
        choice.version = .windows
        model.setSetup(choice, for: cyberpunk.id)
        let windows = GameMenu.items(for: try #require(model.game("steam:1091500")), in: model)
        #expect(windows.first { $0.title == "Graphics" }?.disabled == false)
    }

    @Test("Switching to the Windows version asks Steam for the pair; back to the Mac version clears it")
    func switchVersions() async throws {
        let (model, fixture, _) = try await model("setup-switch", runners: [GameSetupTests.release],
                                                  availability: BackendAvailability(), macBuilds: [1_091_500])
        defer { fixture.remove() }
        model.backendTools = try SteamCompatChoiceTests.pairs(fixture.root)
        let id = "steam:1091500"
        var choice = model.setup(for: id)
        choice.version = .windows
        model.setSetup(choice, for: id)
        #expect(SteamCompatChoice.pending(file: model.compatRequestsFile)[1_091_500] == "cartouche-proton-26.3-dxmt")
        #expect(model.game(id)?.status() == "Windows version")
        choice.version = .mac
        model.setSetup(choice, for: id)
        #expect(SteamCompatChoice.pending(file: model.compatRequestsFile)[1_091_500] == "")
        #expect(model.game(id)?.status() == "Mac version")
    }

    @Test("The Setup rows render for a Windows game and for a game with a Mac build, light and dark")
    func renders() async throws {
        let (model, fixture, _) = try await model("setup-render", runners: [GameSetupTests.release, GameSetupTests.fexBuild],
                                                  availability: BackendAvailability(), macBuilds: [1_091_500])
        defer { fixture.remove() }
        let elden = try #require(model.game("steam:1245620"))
        var cyber = try #require(model.game("steam:1091500"))
        for dark in [false, true] {
            let rows = VStack(alignment: .leading, spacing: 8) { SetupRows(game: elden, model: model, suggestion: .d3dmetal) }
                .frame(width: 330)
            #expect(snapshot(rows, named: "setup-no-d3dmetal", dark: dark).height > 60)
            let mac = VStack(alignment: .leading, spacing: 8) { SetupRows(game: cyber, model: model, suggestion: nil) }.frame(width: 330)
            #expect(snapshot(mac, named: "setup-mac-version", dark: dark).height > 30)
        }
        var choice = model.setup(for: cyber.id)
        choice.version = .windows
        model.setSetup(choice, for: cyber.id)
        cyber = try #require(model.game("steam:1091500"))
        for dark in [false, true] {
            let rows = VStack(alignment: .leading, spacing: 8) { SetupRows(game: cyber, model: model, suggestion: nil) }.frame(width: 330)
            #expect(snapshot(rows, named: "setup-windows-version", dark: dark).height > 60)
            let settings = Form { SetupDefaultsSection(model: model); BackendDownloadsSection(folder: fixture.root.appending(path: "backends")) }.formStyle(.grouped).frame(width: 600, height: 420)
            _ = snapshot(settings, named: "settings-compatibility-defaults", dark: dark)
        }
    }
}
