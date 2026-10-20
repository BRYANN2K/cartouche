import Foundation
import Testing

@testable import NotProtonApp

@Suite("Library browsing")
@MainActor
struct LibraryModelTests {

    private func loaded(_ label: String, running: Bool = true) async throws -> (LibraryModel, SteamFixture, ScratchDefaults) {
        let fixture = try SteamFixture(label)
        try fixture.writeExport()
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, running: running, defaults: scratch)
        await model.load()
        return (model, fixture, scratch)
    }

    private func card(_ model: LibraryModel, _ id: String) throws -> GameCard {
        let game = try #require(model.game(id))
        return GameCard(game: game, isSelected: model.selectedGameID == id, isFavorite: model.isFavorite(id),
                        override: nil, onSelect: {}, onFavorite: {}, onDropCover: { _ in }, menu: { [] }, perform: { _ in })
    }

    @Test("Not installed is gray, selected is in color")
    func grayUntilSelected() async throws {
        let (model, fixture, _) = try await loaded("gray")
        defer { fixture.remove() }
        model.select("steam:1245620")
        #expect(try card(model, "steam:1172470").inColor == false)
        #expect(try card(model, "steam:1245620").inColor == true)
        model.select("steam:1172470")
        #expect(try card(model, "steam:1172470").inColor == true)
    }

    @Test("Favorite from the cover: the star fills, Favorites lists it, and it survives a relaunch")
    func favoriteSurvivesRelaunch() async throws {
        let (model, fixture, scratch) = try await loaded("favorite")
        defer { fixture.remove() }
        #expect(model.screen == .grid(model.screen.sections))
        #expect(!model.isFavorite("steam:1174180"))
        model.toggleFavorite("steam:1174180")
        #expect(model.isFavorite("steam:1174180"))
        model.selection = .favorites
        #expect(model.games(in: .favorites).map(\.name) == ["Red Dead Redemption 2"])
        #expect(model.badge(.favorites) == "1")

        let relaunched = libraryModel(fixture, defaults: scratch)
        await relaunched.load()
        #expect(relaunched.isFavorite("steam:1174180"))
        #expect(relaunched.games(in: .favorites).map(\.name) == ["Red Dead Redemption 2"])
        relaunched.toggleFavorite("steam:1174180")
        #expect(libraryModel(fixture, defaults: scratch).isFavorite("steam:1174180") == false)
    }

    @Test("Favorites with nothing in it says how to add one")
    func emptyFavorites() async throws {
        let (model, fixture, _) = try await loaded("no-favorites")
        defer { fixture.remove() }
        model.selection = .favorites
        #expect(model.screen == .emptyFavorites)
        #expect(model.subtitle == "0 games")
    }

    @Test("Search with no match: the grid is replaced by No games match, and the toolbar reads Search, 0 results")
    func searchNoMatch() async throws {
        let (model, fixture, _) = try await loaded("search")
        defer { fixture.remove() }
        model.searchText = "zelda"
        #expect(model.screen == .noResults("zelda"))
        #expect(model.title == "Search")
        #expect(model.subtitle == "0 results")
        #expect("\(model.title), \(model.subtitle)" == "Search, 0 results")
        #expect(!model.screen.showsPanel)

        model.searchText = "RING"
        #expect(model.searchResults.map(\.name) == ["Elden Ring"])
        #expect(model.subtitle == "1 result")
        model.searchText = "baldurs"
        #expect(model.searchResults.isEmpty)
        model.searchText = "baldur’s"
        #expect(model.searchResults.map(\.name) == ["Baldur’s Gate 3"])
        model.searchText = ""
        #expect(model.title == "All Games")
    }

    @Test("A hidden game leaves the grid and search, stays in Settings, and comes back")
    func hidden() async throws {
        let (model, fixture, scratch) = try await loaded("hidden")
        defer { fixture.remove() }
        model.select("steam:730")
        model.hide("steam:730")
        #expect(!model.games(in: .all).contains { $0.id == "steam:730" })
        model.searchText = "counter"
        #expect(model.searchResults.isEmpty)
        model.searchText = ""
        #expect(model.hiddenGames.map(\.name) == ["Counter-Strike 2"])
        #expect(model.selectedGameID != "steam:730")
        #expect(libraryModel(fixture, defaults: scratch).isHidden("steam:730"))
        model.unhide("steam:730")
        #expect(model.games(in: .all).contains { $0.id == "steam:730" })
    }

    @Test("Games not installed can be left out of the library")
    func showNotInstalled() async throws {
        let (model, fixture, scratch) = try await loaded("installed-only")
        defer { fixture.remove() }
        #expect(model.games(in: .all).count == 8)
        model.showNotInstalled = false
        #expect(model.games(in: .all).count == 6)
        #expect(libraryModel(fixture, defaults: scratch).showNotInstalled == false)
    }

    @Test("Sidebar structure: Library, PC with five sources, and an empty Consoles section")
    func sidebar() async throws {
        let (model, fixture, _) = try await loaded("sidebar")
        defer { fixture.remove() }
        let pc = GameSource.pc.map { LibraryModel.title(.source($0)) }
        #expect([LibraryModel.title(.all), LibraryModel.title(.favorites)] == ["All Games", "Favorites"])
        #expect(pc == ["Steam", "Epic Games", "GOG", "Amazon Games", "Windows Installers"])
        #expect(model.consoles.isEmpty)
        #expect(model.badge(.all) == "8")
        #expect(model.badge(.source(.steam)) == "8")
        for store in [GameSource.epic, .gog, .amazon] {
            #expect(model.badge(.source(store)) == "Sign In")
        }
        #expect(model.badge(.source(.installer)) == nil)
        model.selection = .source(.epic)
        #expect(model.screen == .signIn(.epic))
        #expect(model.subtitle == "Not connected")
    }

    @Test("Section titles are not repeated: headers only in All Games")
    func sectionHeaders() async throws {
        let (model, fixture, _) = try await loaded("headers")
        defer { fixture.remove() }
        model.otherGames = [Game(id: "installer:witcher", source: .installer, name: "The Witcher 3: Wild Hunt", installed: true)]
        #expect(model.screen.sections.map(\.title) == ["Steam", "Windows Installers"])
        model.selection = .source(.steam)
        #expect(model.screen.sections.map(\.title) == [nil])
        #expect(model.title == "Steam")
        model.selection = .source(.installer)
        #expect(model.screen.sections.map(\.title) == [nil])
        model.toggleFavorite("steam:730")
        model.selection = .favorites
        #expect(model.screen.sections.map(\.title) == [nil])
        model.consoles = ["Super Nintendo"]
        model.otherGames.append(Game(id: "console:smw", source: .console("Super Nintendo"), name: "Super Mario World", installed: true))
        model.selection = .source(.console("Super Nintendo"))
        #expect(model.screen.sections.map(\.title) == [nil])
        #expect(model.screen.sections.first?.shape == .square)
        #expect(model.subtitle == "1 game")
    }

    @Test("PC covers are 2:3 and console covers are square")
    func coverShapes() {
        #expect(Game.steam(1, name: "A", installed: true).coverShape == .portrait)
        #expect(abs(CoverShape.portrait.aspectRatio * 3 - 2) < 0.0001)
        #expect(Game(id: "c", source: .console("Nintendo 64"), name: "B", installed: true).coverShape == .square)
    }

    @Test("Changing source keeps a game of that source selected for the panel")
    func selectionFollowsSource() async throws {
        let (model, fixture, _) = try await loaded("selection")
        defer { fixture.remove() }
        model.otherGames = [Game(id: "installer:disco", source: .installer, name: "Disco Elysium", installed: true)]
        model.select("steam:1245620")
        model.selection = .source(.installer)
        #expect(model.selectedGameID == "installer:disco")
        model.selection = .all
        #expect(model.selectedGameID == "installer:disco")
    }

    @Test("An expired store session shows a banner, its games still listed")
    func expiredStore() async throws {
        let (model, fixture, _) = try await loaded("expired")
        defer { fixture.remove() }
        model.stores[.epic] = .expired(account: "player42")
        model.otherGames = [Game(id: "epic:control", source: .epic, name: "Control", installed: false)]
        model.selection = .source(.epic)
        #expect(model.expiredStore == .epic)
        #expect(model.badge(.source(.epic)) == "!")
        #expect(model.screen.sections.first?.games.map(\.name) == ["Control"])
        #expect(model.subtitle == "1 game. Signed in as player42")
    }

    @Test("Nothing connected and nothing added: the welcome screen")
    func welcome() async throws {
        let fixture = try SteamFixture("welcome")
        defer { fixture.remove() }
        let model = libraryModel(fixture, installed: false, defaults: ScratchDefaults())
        await model.load()
        #expect(model.screen == .welcome)
        #expect(model.title == "Library")
        #expect(model.subtitle == "No games yet")
    }

    @Test("While the first import runs, the library is loading")
    func loading() throws {
        let fixture = try SteamFixture("loading")
        defer { fixture.remove() }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        #expect(model.screen == .loading)
        #expect(model.subtitle == "Syncing Steam library…")
        model.loading = false
        #expect(model.screen != .loading)
    }

    @Test("Recently played, for the status item, newest first")
    func recent() async throws {
        let (model, fixture, _) = try await loaded("recent")
        defer { fixture.remove() }
        #expect(model.recentlyPlayed.map(\.name) == ["Elden Ring", "Red Dead Redemption 2", "Counter-Strike 2"])
    }
}

extension LibraryScreen {
    var sections: [LibrarySection] {
        if case .grid(let sections) = self { return sections }
        return []
    }
}
