// The library window's state: which games there are, what the sidebar selects,
// what the grid shows, and every screen state the window can be in.

import Foundation
import Observation

enum AddGamesKind: String, Identifiable, CaseIterable, Sendable {
    case windows, consoles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: String(localized: "Windows Game")
        case .consoles: String(localized: "Console Games")
        }
    }
}

enum SidebarItem: Hashable, Sendable {
    case all
    case favorites
    case source(GameSource)
}

// A store's sign-in, as the sidebar and Settings > Accounts show it
enum StoreConnection: Equatable, Sendable {
    case notConnected
    case waiting
    case connected(account: String)
    case expired(account: String)
}

struct LibrarySection: Identifiable, Equatable {
    let id: String
    // Only All Games names its sections
    let title: String?
    let shape: CoverShape
    let games: [Game]
}

enum LibraryScreen: Equatable {
    case loading
    // Nothing connected and nothing added yet
    case welcome
    case steamInstall
    case signIn(GameSource)
    case grid([LibrarySection])
    case noResults(String)
    case emptyFavorites
    case emptySource(GameSource)

    var showsPanel: Bool {
        switch self {
        case .grid: true
        default: false
        }
    }
}

@MainActor
@Observable
final class LibraryModel {

    var loading = true
    private(set) var steam = SteamImport(presence: .closed, account: nil, games: [], exported: nil) {
        didSet { rebuildGames() }
    }
    // Windows installers and console games are added here by their phases
    var otherGames: [Game] = [] { didSet { rebuildGames() } }
    // Console catalog ids, and their games, which ConsoleCenter keeps here
    var consoles: [String] = []
    var consoleGames: [Game] = [] { didSet { rebuildGames() } }
    var stores: [GameSource: StoreConnection] = [:]
    var runners: [Runner] = []
    // From the registry and Steam's appinfo cache, set by the app
    var backendAvailability = BackendAvailability()
    var backendTools: [BackendTool] = []
    var macBuilds: Set<Int> = [] { didSet { rebuildGames() } }

    // allGames recomputes only when one of its inputs changes, and game(_:)
    // answers from an index instead of scanning the whole list
    private(set) var allGames: [Game] = []
    @ObservationIgnored private var gamesByID: [String: Game] = [:]

    var selection: SidebarItem = .all {
        didSet { if selection != oldValue { keepSelectionVisible() } }
    }
    var selectedGameID: String?
    // Window state the menus reach as well
    var showPanel = true
    var addGames: AddGamesKind?
    var showAddConsoles = false
    var searchFocusRequests = 0
    var searchText = ""
    var isOffline = false
    var showNotInstalled: Bool {
        didSet { defaults.set(showNotInstalled, forKey: Self.showNotInstalledKey) }
    }

    private(set) var choices: LibraryChoices {
        didSet { if choices.setups != oldValue.setups { rebuildGames() } }
    }
    var problem: String?
    // A non-blocking setup note per game, for example switching an installer
    // game to an older Wine than the one that last ran its prefix
    var setupNotices: [String: String] = [:]

    // Folders the setup and launch paths read; tests point them at scratch dirs
    @ObservationIgnored var installsFolder: URL = GameFolder.installs
    @ObservationIgnored var runnersFolder: URL = SupportPaths.runners
    @ObservationIgnored var backendsFolder: URL = BackendInstaller.folder

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let importer: SteamLibraryImporter
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var watcher: Task<Void, Never>?

    static let showNotInstalledKey = "library.showNotInstalled"

    init(store: LibraryStore = LibraryStore(), importer: SteamLibraryImporter = SteamLibraryImporter(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.importer = importer
        self.defaults = defaults
        choices = store.load()
        showNotInstalled = defaults.object(forKey: Self.showNotInstalledKey) as? Bool ?? true
    }

    // MARK: Loading

    func load() async {
        if steam.games.isEmpty { loading = true }
        let importer = importer
        let result = await Task.detached { importer.load() }.value
        apply(result)
    }

    func apply(_ result: SteamImport) {
        steam = result
        loading = false
        if selectedGameID == nil || game(selectedGameID) == nil { keepSelectionVisible() }
    }

    // Reloads when a new export lands or Steam starts or quits, checked every 2 seconds
    func watch(every interval: Duration = .seconds(2)) {
        watcher?.cancel()
        let importer = importer
        // Read now, so a change between this call and the task's start is not missed
        var stamp = importer.exportStamp()
        var running = importer.isRunning()
        watcher = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                tick += 1
                guard let self else { return }
                await self.watchTick(tick: tick, stamp: &stamp, running: &running)
            }
        }
    }

    // One watcher pass. Whether Steam runs is asked every fifth tick, as it
    // spawns ps; the file reads stay off the main thread.
    func watchTick(tick: Int, stamp: inout Date?, running: inout Bool) async {
        let importer = importer
        let was = running, askRunning = tick % 5 == 0
        let (newStamp, nowRunning) = await Task.detached {
            (importer.exportStamp(), askRunning ? importer.isRunning() : was)
        }.value
        if newStamp != stamp || nowRunning != running {
            stamp = newStamp
            running = nowRunning
            await load()
        }
    }

    // MARK: Games

    private func rebuildGames() {
        allGames = (steam.games + otherGames).map(withVersion) + consoleGames
        gamesByID = Dictionary(allGames.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func game(_ id: String?) -> Game? {
        guard let id else { return nil }
        return gamesByID[id]
    }

    var selectedGame: Game? { game(selectedGameID) }

    func installFolder(of game: Game) -> URL? {
        guard game.installed else { return nil }
        if let appID = game.steamAppID { return importer.files.installFolder(appID: appID) }
        return game.executable?.deletingLastPathComponent()
    }

    func isFavorite(_ id: String) -> Bool { choices.favorites.contains(id) }
    func isHidden(_ id: String) -> Bool { choices.hidden.contains(id) }

    func isConnected(_ source: GameSource) -> Bool {
        switch source {
        case .steam: steam.presence != .notInstalled
        case .installer, .console: true
        case .epic, .gog, .amazon:
            switch stores[source] ?? .notConnected {
            case .connected, .expired: true
            case .notConnected, .waiting: false
            }
        }
    }

    // Shown anywhere in the grid: from a connected source, not hidden, installed unless the user wants all
    func isVisible(_ game: Game) -> Bool {
        isConnected(game.source) && !isHidden(game.id) && (showNotInstalled || game.installed)
    }

    func games(in item: SidebarItem) -> [Game] {
        let visible = allGames.filter(isVisible)
        switch item {
        case .all: return visible
        case .favorites: return visible.filter { isFavorite($0.id) }
        case .source(let source): return visible.filter { $0.source == source }
        }
    }

    var hiddenGames: [Game] { allGames.filter { isHidden($0.id) } }

    var searchResults: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return allGames.filter(isVisible).filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Screen

    var screen: LibraryScreen {
        if loading { return .loading }
        if isSearching {
            let results = searchResults
            return results.isEmpty
                ? .noResults(searchText.trimmingCharacters(in: .whitespaces))
                : .grid([LibrarySection(id: "results", title: nil, shape: .portrait, games: results)])
        }
        if allGames.isEmpty && steam.presence == .notInstalled && consoles.isEmpty && !stores.values.contains(where: {
            if case .connected = $0 { return true }
            return false
        }), selection == .all {
            return .welcome
        }
        switch selection {
        case .source(.steam) where steam.presence == .notInstalled:
            return .steamInstall
        case .source(let source) where source.isStore && !isConnected(source):
            return .signIn(source)
        case .favorites:
            let list = games(in: .favorites)
            return list.isEmpty ? .emptyFavorites : .grid([section(id: "favorites", games: list, titled: false)])
        case .source(let source):
            let list = games(in: selection)
            return list.isEmpty ? .emptySource(source) : .grid([section(id: source.id, games: list, titled: false)])
        case .all:
            let visible = games(in: .all)
            if visible.isEmpty { return steam.presence == .notInstalled ? .welcome : .emptySource(.steam) }
            let order = GameSource.pc + consoles.map { GameSource.console($0) }
            let sections = order.compactMap { source -> LibrarySection? in
                let list = visible.filter { $0.source == source }
                return list.isEmpty ? nil : section(id: source.id, games: list, titled: true)
            }
            return .grid(sections)
        }
    }

    private func section(id: String, games: [Game], titled: Bool) -> LibrarySection {
        let source = games.first?.source
        return LibrarySection(id: id, title: titled ? source?.name : nil, shape: games.first?.coverShape ?? .portrait, games: games)
    }

    // An expired store session shows a banner over that store's games
    var expiredStore: GameSource? {
        guard case .source(let source) = selection, case .expired = stores[source] ?? .notConnected else { return nil }
        return source
    }

    // MARK: Toolbar

    var title: String {
        if isSearching { return String(localized: "Search") }
        if screen == .welcome { return String(localized: "Library") }
        return Self.title(selection)
    }

    static func title(_ item: SidebarItem) -> String {
        switch item {
        case .all: String(localized: "All Games")
        case .favorites: String(localized: "Favorites")
        case .source(let source): source.name
        }
    }

    var subtitle: String {
        if isSearching { return Self.count(searchResults.count, result: true) }
        switch screen {
        case .loading: return String(localized: "Syncing Steam library…")
        case .welcome: return String(localized: "No games yet")
        case .steamInstall: return String(localized: "Not installed")
        case .signIn: return String(localized: "Not connected")
        default: break
        }
        let count = Self.count(games(in: selection).count, result: false)
        if case .source(let source) = selection, let account = account(for: source) {
            return String(localized: "\(count). Signed in as \(account)")
        }
        return count
    }

    static func count(_ n: Int, result: Bool) -> String {
        if result { return n == 1 ? String(localized: "1 result") : String(localized: "\(n) results") }
        return n == 1 ? String(localized: "1 game") : String(localized: "\(n) games")
    }

    func account(for source: GameSource) -> String? {
        switch source {
        case .steam: return steam.account?.accountName
        case .epic, .gog, .amazon:
            switch stores[source] ?? .notConnected {
            case .connected(let account), .expired(let account): return account
            case .notConnected, .waiting: return nil
            }
        case .installer, .console: return nil
        }
    }

    // What the sidebar shows after a source's name
    func badge(_ item: SidebarItem) -> String? {
        switch item {
        case .all, .favorites:
            let n = games(in: item).count
            return n > 0 ? String(n) : nil
        case .source(let source):
            if source == .steam && steam.presence == .notInstalled { return String(localized: "Get") }
            if source.isStore {
                switch stores[source] ?? .notConnected {
                case .notConnected, .waiting: return String(localized: "Sign In")
                case .expired: return "!"
                case .connected: break
                }
            }
            let n = games(in: item).count
            return n > 0 ? String(n) : nil
        }
    }

    func isExpired(_ item: SidebarItem) -> Bool {
        guard case .source(let source) = item, case .expired = stores[source] ?? .notConnected else { return false }
        return true
    }

    // MARK: Actions

    func select(_ id: String?) { selectedGameID = id }

    func toggleFavorite(_ id: String) {
        choices.favorites.formSymmetricDifference([id])
        persist()
    }

    func hide(_ id: String) {
        guard choices.hidden.insert(id).inserted else { return }
        persist()
        if selectedGameID == id { keepSelectionVisible() }
    }

    func unhide(_ id: String) {
        choices.hidden.remove(id)
        persist()
    }

    func setCover(_ image: URL, for id: String) {
        do {
            let name = try store.keepCover(image, for: id)
            let old = choices.covers[id]
            choices.covers[id] = name
            persist()
            old.map(store.deleteCover)
        } catch {
            problem = String(localized: "Cartouche couldn’t use this image: \(error.localizedDescription)")
        }
    }

    func clearCover(for id: String) {
        guard let old = choices.covers[id] else { return }
        choices.covers[id] = nil
        persist()
        store.deleteCover(old)
    }

    func coverOverride(for id: String) -> URL? {
        choices.covers[id].map(store.coverURL)
    }

    func setup(for id: String) -> GameSetupChoice { choices.setups[id] ?? GameSetupChoice() }

    func setSetup(_ setup: GameSetupChoice, for id: String, tellSteam: Bool = true) {
        choices.setups[id] = setup
        persist()
        if let game = game(id), game.source == .installer {
            applyInstallerSetup(setup, for: game)
        } else if tellSteam {
            self.tellSteam(id)
        }
    }

    // Several setups at once, saved once, as Steam already has them
    func adoptSetups(_ updates: [String: GameSetupChoice]) {
        guard !updates.isEmpty else { return }
        choices.setups.merge(updates) { _, new in new }
        persist()
        // An installer game's own launcher follows the adopted choice
        for (id, setup) in updates where game(id)?.source == .installer {
            applyInstallerSetup(setup, for: game(id)!)
        }
    }

    private func persist() {
        do {
            try store.save(choices)
        } catch {
            problem = String(localized: "Cartouche couldn’t save your library choices: \(error.localizedDescription)")
        }
    }

    // After the sidebar changes, the panel shows a game that is in view
    private func keepSelectionVisible() {
        let list: [Game]
        switch screen {
        case .grid(let sections): list = sections.flatMap(\.games)
        default: list = []
        }
        if let current = selectedGameID, list.contains(where: { $0.id == current }) { return }
        selectedGameID = list.first?.id
    }

    // The three most recently played, for the status item
    var recentlyPlayed: [Game] {
        Array(allGames.filter { $0.lastPlayed != nil && isVisible($0) }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(3))
    }
}
