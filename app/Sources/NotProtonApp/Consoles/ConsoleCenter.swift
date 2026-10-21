import Foundation
import Observation
import RetroArchKit

@MainActor
@Observable
final class ConsoleCenter {

    let paths: RetroArchPaths
    let settings: ConsolesSettingsModel
    let emulators: EmulatorShelf

    private(set) var added: [Console] = []
    private(set) var games: [ConsoleGame] = []
    private(set) var ownedROMs: Set<String> = []
    private(set) var downloading: Set<String> = []
    var found: [String: Int] = [:]
    var problem: String?
    var folderChoices = WatchedFolders()
    var folderCounts: [String: Int] = [:]
    var folderList: GameFolders?
    var playing: Playing?
    var powerOn: PowerOn?
    var statesChanged = 0
    var extras: ConsoleExtras
    var session = ExtrasSession()

    @ObservationIgnored let cores: CoreManager
    @ObservationIgnored let shelf: ConsoleShelf
    @ObservationIgnored let store: ConsoleLibrary
    @ObservationIgnored let database: ContentDatabase
    @ObservationIgnored let importFlow: ConsoleImport
    @ObservationIgnored weak var library: LibraryModel?
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var scan: Task<Void, Never>?
    @ObservationIgnored var scanAgain = false
    @ObservationIgnored var seen: [String: (stamp: String, found: Identification)] = [:]
    @ObservationIgnored var statesCache: [String: (stamp: Int, states: [SaveState])] = [:]
    @ObservationIgnored var biosCache: [String: (stamp: String, status: BIOSStatus)] = [:]
    @ObservationIgnored var makeRunner: @MainActor (ConsolesSettingsModel) -> (any ConsoleRunning)? = { settings in
        settings.launcher.map { ConsolePlayer(launcher: $0) }
    }
    @ObservationIgnored var playerExtra: [String: String] = [:]
    @ObservationIgnored var runner: (any ConsoleRunning)?
    @ObservationIgnored var watchPlay: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var covers = CoverStore()
    @ObservationIgnored var resolveCore: (@MainActor (String) async throws -> URL)?
    @ObservationIgnored var standaloneEnvironment: [String: String]?
    @ObservationIgnored var sessions = SessionRecords(file: SupportPaths.consoleSession)
    @ObservationIgnored var heartbeatEvery: Duration = .seconds(60)
    @ObservationIgnored var heartbeat: Task<Void, Never>?
    @ObservationIgnored var uninstall = ConsoleUninstall()
    @ObservationIgnored var confirmGameRemoval: @MainActor (ConsoleGameRemoval) -> RemovalAnswer = ConsoleUninstall.confirm
    @ObservationIgnored var confirmRemoval: @MainActor (ConsoleRemoval) -> Bool = ConsoleUninstall.confirm

    // Asks for Local Network before netplay on the local network
    @ObservationIgnored var netplayFlow: PermissionFlow?
    @ObservationIgnored var watchExtras: Task<Void, Never>?
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
        self.extras.isPlaying = { [weak self] in MainActor.assumeIsolated { self?.playing != nil } }
        // Settings > Consoles removes through the same Trash confirmation as the sidebar
        settings.removeConsole = { [weak self] console in
            guard let self else { return nil }
            await self.remove(console.id)
            return self.problem
        }
    }

    var identifier: Identifier { Identifier(database: database) }

    // MARK: Consoles

    func reload() async {
        added = await shelf.added()
        let consoles = Set(added.map(\.id))
        let stored = await store.games().filter { consoles.contains($0.console) }
        let paths = paths
        let (activity, owned) = await Task.detached {
            (SaveStates.latestActivity(in: paths),
             Set(stored.filter { ConsoleUninstall.ownsROM($0.fileURL, in: paths.root) }.map(\.id)))
        }.value
        games = stored.map { game in
            var game = game
            if let played = [game.lastPlayed, activity[game.contentName]].compactMap({ $0 }).max() {
                game.lastPlayed = played
            }
            return game
        }
        ownedROMs = owned
        publish()
    }

    func isAdded(_ id: String) -> Bool { added.contains { $0.id == id } }

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
        if !new.isEmpty, !folderPaths.isEmpty {
            folderChanged()
            await scan?.value
        }
    }

    func remove(_ id: String) async {
        problem = nil
        guard let console = ConsoleCatalog.console(id) else { return }
        if let playing, game(playing.gameID)?.console == id {
            problem = String(localized: "\(console.name) is playing. Quit the game first.")
            return
        }
        let plan = ConsoleRemoval(console: console, games: games(of: id).count,
                                  files: await shelf.filesToRemove(id))
        guard confirmRemoval(plan) else { return }
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

    func menu(for id: String) -> [ConsoleMenuItem] {
        guard let console = ConsoleCatalog.console(id) else { return [] }
        let count = games(of: id).count
        let remove: String
        switch count {
        case 0: remove = String(localized: "Remove \(console.name)…")
        case 1: remove = String(localized: "Remove \(console.name) (its game stays on disk)…")
        default: remove = String(localized: "Remove \(console.name) (\(count) games stay on disk)…")
        }
        let busy = playing.map { game($0.gameID)?.console == id } ?? false
        return [
            ConsoleMenuItem(title: String(localized: "Add \(console.name) Games…"), action: .addGames),
            ConsoleMenuItem(title: remove, action: .remove, destructive: true, disabled: busy),
        ]
    }

    func perform(_ action: ConsoleMenuItem.Action, on id: String) async {
        switch action {
        case .addGames: library?.showAddGames = true
        case .remove: await remove(id)
        }
    }
}

struct ConsoleMenuItem: Identifiable, Equatable {
    enum Action: Equatable { case addGames, remove }

    let title: String
    let action: Action
    var destructive = false
    var disabled = false

    var id: String { title }
}
