// Console games in the library: the consoles the user added, their games, and
// what the sidebar, the sheets and the panel ask about them. RetroArchKit does
// the work; this model keeps what the window shows.

import Foundation
import Observation
import RetroArchKit

@MainActor
@Observable
final class ConsoleCenter {

    let paths: RetroArchPaths
    let settings: ConsolesSettingsModel
    // The standalone emulators found and the one each console plays in (P16)
    let emulators: EmulatorShelf

    private(set) var added: [Console] = []
    private(set) var games: [ConsoleGame] = []
    // Consoles whose core is being downloaded
    private(set) var downloading: Set<String> = []
    // Game files in the watched folders for consoles not added yet, by console
    var found: [String: Int] = [:]
    var problem: String?
    // Whether games found in the folders join on their own, and how many each folder holds
    var folderChoices = WatchedFolders()
    var folderCounts: [String: Int] = [:]
    // The game folders of Settings > Library and onboarding (P18)
    var folderList: GameFolders?
    // The game RetroArch is playing, for the panel and the activity slot
    var playing: Playing?
    // The picture shown for the CRT power-on while a game starts
    var powerOn: PowerOn?
    // Bumped when RetroArch may have written states, so Continue From reads them again
    var statesChanged = 0
    // Achievements, translation, iCloud Drive, the coach and netplay names (P14)
    var extras: ConsoleExtras
    // What RetroArch said of the session: hardcore on, the netplay seat
    var session = ExtrasSession()

    @ObservationIgnored let cores: CoreManager
    @ObservationIgnored let shelf: ConsoleShelf
    @ObservationIgnored let store: ConsoleLibrary
    @ObservationIgnored let database: ContentDatabase
    // The Console Games step of the + sheet
    @ObservationIgnored let importFlow: ConsoleImport
    @ObservationIgnored weak var library: LibraryModel?
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var scan: Task<Void, Never>?
    @ObservationIgnored var scanAgain = false
    // What each file in the folders turned out to be, by path, size and date
    @ObservationIgnored var seen: [String: (stamp: String, found: Identification)] = [:]
    // Plays the games; the RetroArch Settings > Consoles chose, or a stand-in in tests
    @ObservationIgnored var makeRunner: @MainActor (ConsolesSettingsModel) -> (any ConsoleRunning)? = { settings in
        settings.launcher.map { ConsolePlayer(launcher: $0) }
    }
    // For tests and diagnostics: RetroArch settings added to every launch
    @ObservationIgnored var playerExtra: [String: String] = [:]
    @ObservationIgnored var runner: (any ConsoleRunning)?
    @ObservationIgnored var watchPlay: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var covers = CoverStore()
    // The core file a game plays with; tests hand in their own core
    @ObservationIgnored var resolveCore: (@MainActor (String) async throws -> URL)?
    // Plays a game in a standalone emulator; tests hand in their own environment
    @ObservationIgnored var standaloneEnvironment: [String: String]?

    // Asks for Local Network before netplay on the local network (P17's flow)
    @ObservationIgnored var netplayFlow: PermissionFlow?
    @ObservationIgnored var watchExtras: Task<Void, Never>?
    // Cartouche's relay for Coach mode, while a coached game runs
    @ObservationIgnored var coach: CoachRelay?

    init(settings: ConsolesSettingsModel, cores: CoreManager, library: LibraryModel? = nil,
         database: ContentDatabase? = nil, extras: ConsoleExtras? = nil, emulators: EmulatorShelf? = nil) {
        self.settings = settings
        self.extras = extras ?? ConsoleExtras(paths: settings.paths)
        paths = settings.paths
        self.emulators = emulators ?? EmulatorShelf(paths: settings.paths)
        self.cores = cores
        shelf = ConsoleShelf(paths: settings.paths, cores: cores)
        store = ConsoleLibrary(paths: settings.paths)
        let database = database ?? ContentDatabase(paths: settings.paths, source: .qa)
        self.database = database
        importFlow = ConsoleImport(identifier: Identifier(database: database))
        self.library = library
    }

    var identifier: Identifier { Identifier(database: database) }

    // MARK: Consoles

    func reload() async {
        added = await shelf.added()
        let consoles = Set(added.map(\.id))
        // A removed console's games stay in library.json, out of sight, so
        // adding it again brings back their play time
        games = await store.games().filter { consoles.contains($0.console) }
        publish()
    }

    func isAdded(_ id: String) -> Bool { added.contains { $0.id == id } }

    // Downloads each console's core, then shows it in the sidebar
    func add(_ ids: [String]) async {
        problem = nil
        let new = ids.filter { !isAdded($0) }
        downloading.formUnion(new)
        for id in new {
            do {
                try await shelf.add(id)
            } catch {
                problem = String(localized: "\(ConsoleCatalog.console(id)?.name ?? id) could not be added: \(error.localizedDescription)")
            }
            downloading.remove(id)
            await reload()
        }
        await settings.refresh()
        // Games the folders already hold for these consoles come in now
        if !new.isEmpty, !folderPaths.isEmpty { await scanFolders() }
    }

    // Deletes the core no other added console uses. Game files are never touched.
    func remove(_ id: String) async {
        problem = nil
        do {
            try await shelf.remove(id)
        } catch {
            problem = error.localizedDescription
        }
        if library?.selection == .source(.console(id)) { library?.selection = .all }
        await reload()
        await settings.refresh()
    }

    func games(of console: String) -> [ConsoleGame] { games.filter { $0.console == console } }

    // Adds the games, and first the consoles they need that are not added yet.
    // The files stay where they are.
    @discardableResult
    func addGames(_ new: [ConsoleGame]) async -> [ConsoleGame] {
        let consoles = new.map(\.console).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        await add(consoles.filter { !isAdded($0) })
        let ready = new.filter { isAdded($0.console) }
        do {
            let added = try await store.add(ready)
            await reload()
            return added
        } catch {
            problem = error.localizedDescription
            return []
        }
    }

    func game(_ id: String) -> ConsoleGame? { games.first { $0.id == id } }

    // MARK: Library

    // The library window's view of the console games
    private func publish() {
        guard let library else { return }
        library.consoles = added.map(\.id)
        library.consoleGames = games.map(Self.libraryGame)
    }

    static func libraryGame(_ game: ConsoleGame) -> Game {
        var entry = Game(id: game.id, source: .console(game.console), name: game.name, installed: game.exists)
        entry.lastPlayed = game.lastPlayed
        entry.playtimeMinutes = Int(game.playSeconds / 60)
        entry.console = game
        return entry
    }

    // MARK: Menus

    // What right-clicking a console in the sidebar offers
    func menu(for id: String) -> [ConsoleMenuItem] {
        guard let console = ConsoleCatalog.console(id) else { return [] }
        let count = games(of: id).count
        let remove: String
        switch count {
        case 0: remove = String(localized: "Remove \(console.name)")
        case 1: remove = String(localized: "Remove \(console.name) (its game stays on disk)")
        default: remove = String(localized: "Remove \(console.name) (\(count) games stay on disk)")
        }
        return [
            ConsoleMenuItem(title: String(localized: "Add \(console.name) Games…"), action: .addGames),
            ConsoleMenuItem(title: remove, action: .remove, destructive: true),
        ]
    }

    func perform(_ action: ConsoleMenuItem.Action, on id: String) async {
        switch action {
        case .addGames: library?.addGames = .consoles
        case .remove: await remove(id)
        }
    }
}

struct ConsoleMenuItem: Identifiable, Equatable {
    enum Action: Equatable { case addGames, remove }

    let title: String
    let action: Action
    var destructive = false

    var id: String { title }
}
