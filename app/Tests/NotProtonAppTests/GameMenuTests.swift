import Foundation
import Testing

@testable import NotProtonApp

@Suite("Keyboard and menus")
@MainActor
struct GameMenuTests {

    private func setUp(_ label: String) async throws -> (LibraryModel, GameActionRunner, Box<[URL]>, SteamFixture) {
        let fixture = try SteamFixture(label)
        try fixture.writeExport()
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        await model.load()
        let opened = Box<[URL]>([])
        let runner = GameActionRunner(model: model, open: { opened.value.append($0) }, reveal: { opened.value.append($0) },
                                      chooseImage: { nil })
        return (model, runner, opened, fixture)
    }

    private func item(_ items: [GameMenuItem], _ shortcut: Shortcut) -> GameMenuItem? {
        items.first { $0.shortcut == shortcut }
    }

    @Test("Shortcuts work: with a game selected, ⌘D adds it to Favorites")
    func commandD() async throws {
        let (model, runner, _, fixture) = try await setUp("cmd-d")
        defer { fixture.remove() }
        model.select("steam:1174180")
        let game = try #require(model.selectedGame)
        let favorite = try #require(item(GameMenu.items(for: game, in: model), GameMenu.favorite))
        #expect(favorite.title == "Add to Favorites")
        #expect(favorite.shortcut?.label == "⌘D")
        runner.perform(try #require(favorite.action), on: game)
        #expect(model.isFavorite("steam:1174180"))
        #expect(model.games(in: .favorites).map(\.name) == ["Red Dead Redemption 2"])
        #expect(item(GameMenu.items(for: game, in: model), GameMenu.favorite)?.title == "Remove from Favorites")
    }

    @Test("⌘I is Get Info: it selects the game and shows its panel")
    func commandI() async throws {
        let (model, _, _, fixture) = try await setUp("cmd-i")
        defer { fixture.remove() }
        model.showPanel = false
        let game = try #require(model.game("steam:730"))
        var shown = 0
        let runner = GameActionRunner(model: model, open: { _ in }, showInfo: { shown += 1; model.showPanel = true })
        let info = try #require(item(GameMenu.items(for: game, in: model), GameMenu.getInfo))
        #expect(info.title == "Get Info")
        #expect(info.shortcut?.label == "⌘I")
        runner.perform(try #require(info.action), on: game)
        #expect(model.selectedGameID == "steam:730")
        #expect(model.showPanel)
        #expect(shown == 1)
    }

    @Test("Play is ⌘↩ and goes through Steam; a game not installed offers Install instead")
    func play() async throws {
        let (model, runner, opened, fixture) = try await setUp("play")
        defer { fixture.remove() }
        let elden = try #require(model.game("steam:1245620"))
        let play = try #require(item(GameMenu.items(for: elden, in: model), GameMenu.play))
        #expect(play.title == "Play")
        #expect(play.shortcut?.label == "⌘↩")
        runner.perform(.play, on: elden)
        let apex = try #require(model.game("steam:1172470"))
        #expect(GameMenu.items(for: apex, in: model).first?.title == "Install")
        runner.perform(.install, on: apex)
        runner.perform(.verifyFiles, on: elden)
        runner.perform(.showInSteam, on: elden)
        #expect(opened.value.map(\.absoluteString) == ["steam://rungameid/1245620", "steam://install/1172470",
                                                         "steam://validate/1245620", "steam://nav/games/details/1245620"])
        model.isOffline = true
        #expect(GameMenu.items(for: apex, in: model).first?.disabled == true)
    }

    @Test("The context menu lists every action, and the Game menu in the menu bar shows the same list")
    func everyActionInTheMenuBar() async throws {
        let (model, runner, opened, fixture) = try await setUp("menubar")
        defer { fixture.remove() }
        let game = try #require(model.game("steam:730"))
        let actions = GameMenu.items(for: game, in: model).flatMap(\.flatActions)
        #expect(actions.contains(.play) && actions.contains(.toggleFavorite) && actions.contains(.getInfo))
        #expect(actions.contains(.graphics(.dxmt)) && actions.contains(.hide) && actions.contains(.changeCover))
        #expect(actions.contains(.showInFinder) && actions.contains(.uninstall))

        let app = try String(contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/App/AppCommands.swift"), encoding: .utf8)
        let grid = try String(contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/Library/Views/LibraryGrid.swift"), encoding: .utf8)
        #expect(app.contains("GameMenuContent(items: GameMenu.items(for: game, in: model, stores: stores))"))
        #expect(grid.contains("menu: { GameMenu.items(for: game, in: model, stores: stores) }"))

        runner.perform(.graphics(.dxmt), on: game)
        #expect(model.setup(for: game.id).graphics == .dxmt)
        runner.perform(.showInFinder, on: game)
        #expect(opened.value.last?.lastPathComponent == "Counter-Strike 2")
        runner.perform(.hide, on: game)
        #expect(model.isHidden(game.id))
        #expect(GameMenu.items(for: game, in: model).contains { $0.action == .unhide })
    }

    @Test("Main actions have the shortcuts the spec names")
    func shortcuts() {
        #expect([GameMenu.play.label, GameMenu.getInfo.label, GameMenu.favorite.label] == ["⌘↩", "⌘I", "⌘D"])
    }

    @Test("Settings ⌘, and Find ⌘F are in the app's menus, and Install no longer takes ⌘I")
    func appShortcuts() throws {
        let app = try String(contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/App.swift"), encoding: .utf8)
        let menus = try String(contentsOf: IdentityTests.repoRoot.appending(path: "app/Sources/NotProtonApp/App/AppCommands.swift"), encoding: .utf8)
        #expect(app.contains("Settings {"))
        #expect(menus.contains("Button(\"Find\")") && menus.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        #expect(!menus.contains(".keyboardShortcut(\"i\", modifiers: .command)"))
        #expect(app.contains("MenuBarExtra(isInserted: $showInMenuBar)"))
    }
}
