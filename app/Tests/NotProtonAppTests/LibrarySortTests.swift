import Foundation
import Testing

@testable import NotProtonApp

@Suite("Library sort and filter")
@MainActor
struct LibrarySortTests {

    @MainActor
    struct Scene {
        let fixture: SteamFixture
        let scratch = ScratchDefaults()
        let model: LibraryModel

        init(_ label: String, steam: [Game] = [], other: [Game] = [], consoles: [Game] = []) throws {
            fixture = try SteamFixture(label)
            model = libraryModel(fixture, defaults: scratch)
            model.stores = [.epic: .connected(account: "player"), .gog: .connected(account: "player")]
            model.consoles = Array(Set(consoles.compactMap { game in
                if case .console(let id) = game.source { return id }
                return nil
            }))
            model.otherGames = other
            model.consoleGames = consoles
            model.apply(SteamImport(presence: .closed, account: nil, games: steam, exported: nil))
        }
    }

    static func game(_ name: String, _ source: GameSource = .steam, installed: Bool = true,
                     played: Int? = nil, minutes: Int = 0) -> Game {
        Game(id: "\(source.id):\(name)", source: source, name: name, installed: installed,
             lastPlayed: played.map { Date(timeIntervalSince1970: Double($0) * 86_400) }, playtimeMinutes: minutes)
    }

    static let mixed: [Game] = [
        game("Quake", played: 20, minutes: 300),
        game("Hades", played: 40, minutes: 900),
        game("Zork", installed: false, played: 30, minutes: 60),
        game("Celeste", installed: false),
        game("Balatro"),
    ]

    @Test("Name is the default: natural order, no case, numbers by value")
    func nameByDefault() throws {
        let scene = try Scene("sort-name", steam: ["zelda 10", "Zelda 2", "alpha", "Beta"].map { Self.game($0) })
        defer { scene.fixture.remove() }
        #expect(scene.model.sort == .name)
        #expect(scene.model.games(in: .all).map(\.name) == ["alpha", "Beta", "Zelda 2", "zelda 10"])
    }

    @Test("Last Played: most recent first, games never played at the bottom by name")
    func lastPlayed() throws {
        let scene = try Scene("sort-last", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .lastPlayed
        #expect(scene.model.games(in: .all).map(\.name) == ["Hades", "Zork", "Quake", "Balatro", "Celeste"])
    }

    @Test("Play Time: most played first, zero minutes at the bottom by name")
    func playTime() throws {
        let scene = try Scene("sort-time", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .playTime
        #expect(scene.model.games(in: .all).map(\.name) == ["Hades", "Quake", "Zork", "Balatro", "Celeste"])
    }

    @Test("Equal values break by name, natural order included")
    func ties() throws {
        let tied = ["Game 10", "game 2", "Alpha"].map { Self.game($0, played: 5, minutes: 60) }
        let scene = try Scene("sort-ties", steam: tied)
        defer { scene.fixture.remove() }
        scene.model.sort = .lastPlayed
        #expect(scene.model.games(in: .all).map(\.name) == ["Alpha", "game 2", "Game 10"])
        scene.model.sort = .playTime
        #expect(scene.model.games(in: .all).map(\.name) == ["Alpha", "game 2", "Game 10"])
    }

    @Test("Two games with one name keep one order, whichever list they came in")
    func sameName() throws {
        let one = Self.game("Portal", .steam), two = Self.game("Portal", .epic)
        let first = try Scene("sort-same-a", steam: [one], other: [two])
        let second = try Scene("sort-same-b", steam: [one], other: [two])
        defer { first.fixture.remove(); second.fixture.remove() }
        second.model.sort = .playTime
        second.model.sort = .name
        #expect(first.model.games(in: .all).map(\.id) == second.model.games(in: .all).map(\.id))
    }

    @Test("All keeps its store sections and sorts inside each one")
    func sections() throws {
        let scene = try Scene("sort-sections", steam: Self.mixed, other: [
            Self.game("Witcher", .gog), Self.game("Alan Wake", .gog), Self.game("Fortnite", .epic),
        ], consoles: [
            Self.game("Metroid", .console("switch"), played: 3, minutes: 14),
            Self.game("Mario Kart", .console("switch"), played: 9, minutes: 200),
            Self.game("Animal Crossing", .console("switch")),
        ])
        defer { scene.fixture.remove() }
        scene.model.sort = .playTime
        let sections = scene.model.screen.sections
        #expect(sections.map(\.id) == ["steam", "epic", "gog", "console:switch"])
        #expect(sections[0].games.map(\.name) == ["Hades", "Quake", "Zork", "Balatro", "Celeste"])
        #expect(sections[2].games.map(\.name) == ["Alan Wake", "Witcher"])
        #expect(sections[3].games.map(\.name) == ["Mario Kart", "Metroid", "Animal Crossing"])
    }

    @Test("One source and Favorites sort a flat list")
    func flatLists() throws {
        let scene = try Scene("sort-flat", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .lastPlayed
        scene.model.selection = .source(.steam)
        #expect(scene.model.screen.sections.map(\.title) == [nil])
        #expect(scene.model.screen.sections[0].games.map(\.name) == ["Hades", "Zork", "Quake", "Balatro", "Celeste"])
        for id in ["steam:Balatro", "steam:Quake", "steam:Hades"] { scene.model.toggleFavorite(id) }
        scene.model.selection = .favorites
        #expect(scene.model.screen.sections.map(\.title) == [nil])
        #expect(scene.model.screen.sections[0].games.map(\.name) == ["Hades", "Quake", "Balatro"])
    }

    @Test("Search results follow the sort and stay inside the filter")
    func search() throws {
        let scene = try Scene("sort-search", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .playTime
        scene.model.searchText = "e"
        #expect(scene.model.screen.sections[0].games.map(\.name) == ["Hades", "Quake", "Celeste"])
        scene.model.installedOnly = true
        #expect(scene.model.screen.sections[0].games.map(\.name) == ["Hades", "Quake"])
        scene.model.searchText = "zork"
        #expect(scene.model.screen == .noResults("zork"))
        #expect(scene.model.screen.showsLibraryControls)
    }

    @Test("Installed leaves consoles in, drops the rest, and the counts follow")
    func installedOnly() throws {
        let scene = try Scene("filter-counts", steam: Self.mixed, consoles: [Self.game("Metroid", .console("switch"))])
        defer { scene.fixture.remove() }
        #expect(scene.model.badge(.source(.steam)) == "5")
        scene.model.installedOnly = true
        #expect(scene.model.showNotInstalled == false)
        #expect(scene.model.games(in: .all).map(\.name) == ["Balatro", "Hades", "Metroid", "Quake"])
        #expect(scene.model.badge(.source(.steam)) == "3")
        #expect(scene.model.subtitle.hasPrefix("4 games"))
    }

    @Test("Installed moves the selection off a game it hides, to the first game shown")
    func selection() throws {
        let scene = try Scene("filter-selection", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.select("steam:Zork")
        scene.model.installedOnly = true
        #expect(scene.model.selectedGameID == "steam:Balatro")
        scene.model.select("steam:Quake")
        scene.model.installedOnly = false
        #expect(scene.model.selectedGameID == "steam:Quake", "a game still shown keeps the selection")
        scene.model.sort = .playTime
        #expect(scene.model.selectedGameID == "steam:Quake")
    }

    @Test("A game uninstalled under the filter leaves the selection too")
    func uninstallUnderFilter() throws {
        let game = Game.steam(440, name: "Team Fortress 2", installed: true)
        let other = Game.steam(620, name: "Portal 2", installed: true)
        let scene = try Scene("filter-uninstall", steam: [game, other])
        defer { scene.fixture.remove() }
        scene.model.installedOnly = true
        scene.model.select(game.id)
        scene.model.didUninstallSteam(appID: 440)
        #expect(scene.model.selectedGameID == other.id)
    }

    @Test("When the filter hides everything: its own empty state, no selection, no panel, the sort ball stays")
    func filterEmptied() throws {
        let scene = try Scene("filter-empty", steam: [Self.game("Zork", installed: false)],
                              other: [Self.game("Fortnite", .epic, installed: false)])
        defer { scene.fixture.remove() }
        scene.model.toggleFavorite("steam:Zork")
        scene.model.select("steam:Zork")
        scene.model.installedOnly = true
        for item: SidebarItem in [.all, .favorites, .source(.steam), .source(.epic)] {
            scene.model.selection = item
            #expect(scene.model.screen == .noInstalledGames, "\(item)")
            #expect(scene.model.screen.showsLibraryControls)
            #expect(!scene.model.screen.showsPanel)
            #expect(scene.model.selectedGameID == nil)
        }
        scene.model.installedOnly = false
        #expect(scene.model.selectedGameID != nil)
    }

    @Test("A list with nothing in it keeps its own empty state, filter or not")
    func trulyEmpty() throws {
        let scene = try Scene("filter-truly-empty", steam: [Self.game("Quake")])
        defer { scene.fixture.remove() }
        scene.model.installedOnly = true
        scene.model.selection = .favorites
        #expect(scene.model.screen == .emptyFavorites)
        #expect(!scene.model.screen.showsLibraryControls)
        scene.model.selection = .source(.gog)
        #expect(scene.model.screen == .emptySource(.gog))
        scene.model.selection = .source(.amazon)
        #expect(scene.model.screen == .signIn(.amazon))
        #expect(!scene.model.screen.showsLibraryControls)
    }

    @Test("The sort ball shows with the grid and never on the loading or welcome screens")
    func controlScreens() throws {
        let scene = try Scene("filter-controls", steam: Self.mixed)
        defer { scene.fixture.remove() }
        #expect(scene.model.screen.showsLibraryControls)
        #expect(!LibraryScreen.loading.showsLibraryControls)
        #expect(!LibraryScreen.welcome.showsLibraryControls)
        #expect(!LibraryScreen.steamInstall.showsLibraryControls)
    }

    @Test("Sort and filter survive a relaunch; an unknown stored sort falls back to Name")
    func persistence() throws {
        let scene = try Scene("sort-relaunch", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .playTime
        scene.model.installedOnly = true
        let relaunched = libraryModel(scene.fixture, defaults: scene.scratch)
        #expect(relaunched.sort == .playTime)
        #expect(relaunched.installedOnly)
        scene.scratch.defaults.set("size", forKey: LibraryModel.sortKey)
        #expect(libraryModel(scene.fixture, defaults: scene.scratch).sort == .name)
    }

    @Test("The sort reaches games that load later")
    func loadedLater() throws {
        let scene = try Scene("sort-later", steam: Self.mixed)
        defer { scene.fixture.remove() }
        scene.model.sort = .playTime
        scene.model.apply(SteamImport(presence: .closed, account: nil,
                                      games: Self.mixed + [Self.game("Doom", minutes: 5_000)], exported: nil))
        #expect(scene.model.games(in: .all).first?.name == "Doom")
    }

    @Test("The controller walks the sorted grid and survives an empty filter")
    func couch() throws {
        let scene = try Scene("sort-couch", steam: Self.mixed)
        defer { scene.fixture.remove() }
        let couch = CouchNavigator(defaults: scene.scratch.defaults)
        couch.library = scene.model
        couch.gridWidth = 1000
        scene.model.sort = .playTime
        scene.model.select(CouchNavigator.games(scene.model).first?.id)
        #expect(scene.model.selectedGame?.name == "Hades")
        couch.perform(.move(.right))
        #expect(scene.model.selectedGame?.name == "Quake")
        couch.perform(.move(.right))
        #expect(scene.model.selectedGame?.name == "Zork")
        couch.perform(.move(.left))
        #expect(scene.model.selectedGame?.name == "Quake")

        let empty = try Scene("filter-couch", steam: [Self.game("Zork", installed: false)])
        defer { empty.fixture.remove() }
        let emptyCouch = CouchNavigator(defaults: empty.scratch.defaults)
        emptyCouch.library = empty.model
        emptyCouch.play = { _ in Issue.record("nothing to play") }
        empty.model.installedOnly = true
        for command in [CouchCommand.move(.down), .accept, .accept, .nextList, .previousList] { emptyCouch.perform(command) }
        #expect(empty.model.screen == .noInstalledGames)
    }

    @Test("The sort menu's labels are translated in every language")
    func translated() throws {
        let copy = EnglishCopyTests()
        let table = try copy.table("Localizable.xcstrings")
        let keys = ["Name", "Last Played", "Play Time", "Sort · %@", "No installed games", "library.filter.installed", "Installed Only"]
        for key in keys {
            for language in ["fr", "it", "zh-Hans"] {
                #expect(copy.value(table[key], language)?.isEmpty == false, "\(language): \(key)")
            }
        }
        #expect(copy.value(table["library.filter.installed"], "fr") == "Installés")
        #expect(copy.value(table["library.filter.installed"], "en") == "Installed")
        #expect(copy.value(table["Installed Only"], "fr") == "Installés uniquement")
    }
}
