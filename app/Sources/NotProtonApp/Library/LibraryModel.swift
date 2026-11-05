
import Foundation
import Observation

enum SidebarItem: Hashable, Sendable {
    case all
    case favorites
    case source(GameSource)
}

enum StoreConnection: Equatable, Sendable {
    case notConnected
    case waiting
    case connected(account: String)
    case expired(account: String)
}

struct LibrarySection: Identifiable, Equatable {
    let id: String
    let title: String?
    let shape: CoverShape
    let games: [Game]
}

enum LibrarySort: String, CaseIterable, Sendable {
    case name, lastPlayed, playTime

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .lastPlayed: String(localized: "Last Played")
        case .playTime: String(localized: "Play Time")
        }
    }

    func ordered(_ games: [Game]) -> [Game] { games.sorted(by: precedes) }

    private func precedes(_ a: Game, _ b: Game) -> Bool {
        switch self {
        case .name: break
        case .lastPlayed:
            if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
        case .playTime:
            if a.playtimeMinutes != b.playtimeMinutes { return a.playtimeMinutes > b.playtimeMinutes }
        }
        let names = a.name.localizedStandardCompare(b.name)
        return names == .orderedSame ? a.id < b.id : names == .orderedAscending
    }
}

enum LibraryScreen: Equatable {
    case loading
    case welcome
    case steamInstall
    case signIn(GameSource)
    case grid([LibrarySection])
    case noResults(String)
    case emptyFavorites
    case emptySource(GameSource)
    case noInstalledGames

    var showsLibraryControls: Bool {
        switch self {
        case .grid, .noResults, .noInstalledGames: true
        default: false
        }
    }

    var showsStoreLink: Bool {
        switch self {
        case .emptySource: true
        default: showsLibraryControls
        }
    }

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
    var otherGames: [Game] = [] { didSet { rebuildGames() } }
    var consoles: [String] = []
    var consoleGames: [Game] = [] { didSet { rebuildGames() } }
    var stores: [GameSource: StoreConnection] = [:] { didSet { keepSourceInSidebar() } }
    // True: added with the +. False: removed by right-click. Absent: its games decide.
    private var sidebarStores: [GameSource: Bool] {
        didSet {
            let saved = Dictionary(uniqueKeysWithValues: sidebarStores.map { ($0.key.id, $0.value) })
            defaults.set(saved, forKey: Self.sidebarStoresKey)
            keepSourceInSidebar()
        }
    }
    var runners: [Runner] = []
    // Loaded off the main actor with runners; empty until then
    var runnerManifest = RunnerManifest(format: RunnerManifest.format, revision: 0, builds: [])
    var backendAvailability = BackendAvailability()
    var backendTools: [BackendTool] = []
    var steamSizes: [Int: SteamAppInfo.Storage] = [:] { didSet { rebuildGames() } }
    var macBuilds: Set<Int> = [] { didSet { rebuildGames() } }

    private(set) var allGames: [Game] = []
    // allGames in the chosen order, sorted once: every list reads this many times per frame
    private var sortedGames: [Game] = []
    @ObservationIgnored private var gamesByID: [String: Game] = [:]

    var selection: SidebarItem = .all {
        didSet { if selection != oldValue { keepSelectionVisible() } }
    }
    var selectedGameID: String?
    var showPanel = true
    var showSidebar = true
    var showAddGames = false
    // The console import flow, opened from Add Games for dropped console games
    var showConsoleImport = false
    var verificationRequest: Game?
    var installRequest: Game?
    var showAddConsoles = false
    var showAddStores = false
    // The game whose Change Cover sheet searches Steam; nil keeps the sheet closed
    var coverSearch: Game?
    var searchFocusRequests = 0
    var searchText = ""
    var isOffline = false
    var showNotInstalled: Bool {
        didSet {
            defaults.set(showNotInstalled, forKey: Self.showNotInstalledKey)
            keepSelectionVisible()
        }
    }
    var sort: LibrarySort {
        didSet {
            defaults.set(sort.rawValue, forKey: Self.sortKey)
            sortedGames = sort.ordered(allGames)
        }
    }
    var installedOnly: Bool {
        get { !showNotInstalled }
        set { showNotInstalled = !newValue }
    }

    private(set) var choices: LibraryChoices {
        didSet { if choices.setups != oldValue.setups { rebuildGames() } }
    }
    var problem: String?
    var setupNotices: [String: String] = [:]
    // Re-identification's unsure answers, game ID → name the panel offers until the user renames.
    var nameSuggestions: [String: String] = [:]
    // An installer game's programs it can start with, game ID → the last off-thread scan of its folder.
    var exeOptions: [String: GameExecutable.Options] = [:]
    // Installer games whose program is being changed, runtimes included: their menus wait.
    var changingExe: Set<String> = []
    @ObservationIgnored var exeWinetricks: GameExecutable.Winetricks = InstallerWinetricks.run

    // Where new installer and store games go
    var installsFolder: URL
    // Earlier games locations that still hold games, scanned after installsFolder
    private(set) var previousInstalls: [URL]
    // Set by the app: the installer follows a new games location without a relaunch
    @ObservationIgnored var onGamesLocationChange: (@MainActor (URL) -> Void)?
    @ObservationIgnored var runnersFolder: URL = SupportPaths.runners
    @ObservationIgnored var backendsFolder: URL = BackendInstaller.folder
    // Rescans runners and Steam's tool lists; set by the app
    @ObservationIgnored var reloadRunners: (@MainActor () async -> Void)?
    // Set by the app: the Steam integration upkeep waits for Steam to quit
    @ObservationIgnored var onSteamQuit: (@MainActor () async -> Void)?

    @ObservationIgnored let store: LibraryStore
    // The per-game profiles the in-game menu shares, next to library.json
    @ObservationIgnored let profiles: OverlayProfileStore
    @ObservationIgnored var profileCache: [String: OverlaySettings] = [:]
    // One walk per installed game answers DLSS and the anti-cheat; launches await it before writing variables
    var folderScans: [String: GameDiskScan] = [:]
    @ObservationIgnored var scanning: [String: Task<GameDiskScan, Never>] = [:]
    @ObservationIgnored var scanRequests: Set<String> = []
    @ObservationIgnored var scanTargets: [String: URL] = [:]
    @ObservationIgnored var folderScanner: @Sendable (URL) -> GameDiskScan = { GameDiskScan.scan(in: $0) }
    // Plays waiting on the walk, by game: a second Play joins the wait instead of launching twice
    @ObservationIgnored var pendingPlays: [String: Task<Void, Never>] = [:]
    // Per game: the last launch really wrote CARTOUCHE_FRAMEGEN=1, so the library is in the game
    @ObservationIgnored var framegenLaunched: [String: Bool] = [:]
    var profileRevision = 0
    // Set by the app: the anti-cheat a game ships with, from the compatibility data
    @ObservationIgnored var antiCheat: @MainActor (Game) -> String? = { _ in nil }
    @ObservationIgnored let importer: SteamLibraryImporter
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var watcher: Task<Void, Never>?

    static let showNotInstalledKey = "library.showNotInstalled"
    static let sortKey = "library.sort"
    static let sidebarStoresKey = "library.sidebarStores"

    init(store: LibraryStore = LibraryStore(), importer: SteamLibraryImporter = SteamLibraryImporter(),
         defaults: UserDefaults = .standard) {
        self.store = store
        self.importer = importer
        self.defaults = defaults
        installsFolder = GameFolder.current(defaults)
        previousInstalls = GameFolder.previous(defaults)
        choices = store.load()
        profiles = OverlayProfileStore(folder: store.folder.appending(path: "Overlay", directoryHint: .isDirectory))
        showNotInstalled = defaults.object(forKey: Self.showNotInstalledKey) as? Bool ?? true
        sort = defaults.string(forKey: Self.sortKey).flatMap(LibrarySort.init(rawValue:)) ?? .name
        let saved = defaults.dictionary(forKey: Self.sidebarStoresKey) as? [String: Bool] ?? [:]
        sidebarStores = Dictionary(uniqueKeysWithValues: saved.compactMap { id, shown in
            GameSource(id: id).flatMap { $0.isStore ? ($0, shown) : nil }
        })
        migrateProfiles()
    }

    // MARK: Loading

    @ObservationIgnored private var loadGeneration = 0
    // The export's stamp read just before the last load, so the watcher's baseline cannot skip a newer export
    @ObservationIgnored private var loadedExportStamp: Date?? = nil
    func load() async {
        loadGeneration += 1
        let run = loadGeneration
        if steam.games.isEmpty { loading = true }
        let importer = importer
        let (stamp, result) = await Task.detached { (importer.exportStamp(), importer.load()) }.value
        // A load started later owns the result
        guard run == loadGeneration else { return }
        loadedExportStamp = .some(stamp)
        apply(result)
    }

    func apply(_ result: SteamImport) {
        steam = result
        loading = false
        if selectedGameID == nil || game(selectedGameID) == nil { keepSelectionVisible() }
    }

    func didUninstallSteam(appID: Int) {
        guard let index = steam.games.firstIndex(where: { $0.steamAppID == appID }) else { return }
        steam.games[index].installed = false
        steam.games[index].storageBytes = nil
    }

    func watch(every interval: Duration = .seconds(2)) {
        watcher?.cancel()
        let importer = importer
        watcher = Task { [weak self] in
            // The baseline (a file stat and a process probe) never runs on the main actor.
            var (stamp, running) = await Task.detached {
                (importer.exportStamp(), importer.isRunning())
            }.value
            if let self, case .some(let loaded) = self.loadedExportStamp { stamp = loaded }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                tick += 1
                guard let self else { return }
                await self.watchTick(tick: tick, stamp: &stamp, running: &running)
            }
        }
    }

    // Steam's running state is asked every fifth tick (it spawns ps); file reads stay off the main thread.
    func watchTick(tick: Int, stamp: inout Date?, running: inout Bool) async {
        let importer = importer
        let was = running, askRunning = tick % 5 == 0
        let (newStamp, nowRunning) = await Task.detached {
            (importer.exportStamp(), askRunning ? importer.isRunning() : was)
        }.value
        let quit = running && !nowRunning
        if newStamp != stamp || nowRunning != running {
            stamp = newStamp
            running = nowRunning
            await load()
        }
        if quit, let onSteamQuit { Task { await onSteamQuit() } }
    }

    // MARK: Games

    private func rebuildGames() {
        allGames = (steam.games + otherGames).map { game in
            var game = withVersion(game)
            if game.storageBytes == nil, let id = game.steamAppID, let sizes = steamSizes[id] {
                let bytes = game.version == .mac ? sizes.mac : sizes.windows
                if bytes > 0 { game.storageBytes = bytes; game.storageEstimated = true }
            }
            return game
        } + consoleGames
        sortedGames = sort.ordered(allGames)
        gamesByID = Dictionary(allGames.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if let id = selectedGameID, gamesByID[id].map({ showNotInstalled || $0.installed }) != true {
            keepSelectionVisible()
        }
        keepSourceInSidebar()
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
        case .epic, .gog, .amazon, .ea, .ubisoft:
            switch stores[source] ?? .notConnected {
            case .connected, .expired: true
            case .notConnected, .waiting: false
            }
        }
    }

    private func isListed(_ game: Game) -> Bool { isConnected(game.source) && !isHidden(game.id) }

    func isVisible(_ game: Game) -> Bool { isListed(game) && (showNotInstalled || game.installed) }

    private func belongs(_ game: Game, to item: SidebarItem) -> Bool {
        switch item {
        case .all: true
        case .favorites: isFavorite(game.id)
        case .source(let source): game.source == source
        }
    }

    func games(in item: SidebarItem) -> [Game] {
        sortedGames.filter { isVisible($0) && belongs($0, to: item) }
    }

    private func filterHidesEverything(in item: SidebarItem) -> Bool {
        !showNotInstalled && games(in: item).isEmpty && sortedGames.contains { isListed($0) && belongs($0, to: item) }
    }

    var hiddenGames: [Game] { allGames.filter { isHidden($0.id) } }

    var searchResults: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return sortedGames.filter(isVisible).filter {
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
        case _ where filterHidesEverything(in: selection):
            return .noInstalledGames
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
        let shape: CoverShape = games.contains { $0.coverShape == .portrait } ? .portrait : .square
        return LibrarySection(id: id, title: titled ? source?.name : nil, shape: shape, games: games)
    }

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
        var subtitle = count
        if case .source(let source) = selection, let account = account(for: source) {
            subtitle = String(localized: "\(count). Signed in as \(account)")
        }
        if steam.presence == .closed && steam.exported != nil {
            switch selection {
            case .all, .source(.steam):
                subtitle += (subtitle.hasSuffix(".") ? " " : ". ")
                    + String(localized: "Steam is closed. Some details may be out of date.")
            default: break
            }
        }
        return subtitle
    }

    static func count(_ n: Int, result: Bool) -> String {
        if result { return n == 1 ? String(localized: "1 result") : String(localized: "\(n) results") }
        return n == 1 ? String(localized: "1 game") : String(localized: "\(n) games")
    }

    func account(for source: GameSource) -> String? {
        switch source {
        case .steam: return steam.account?.accountName
        case .epic, .gog, .amazon, .ea, .ubisoft:
            switch stores[source] ?? .notConnected {
            case .connected(let account), .expired(let account):
                let shown = StoreConnection.shownAccount(account)
                return shown.isEmpty && !account.isEmpty ? nil : shown
            case .notConnected, .waiting: return nil
            }
        case .installer, .console: return nil
        }
    }

    func badge(_ item: SidebarItem) -> String? {
        switch item {
        case .all, .favorites:
            let n = games(in: item).count
            return n > 0 ? String(n) : nil
        case .source(let source):
            if source == .steam && steam.presence == .notInstalled { return String(localized: "Get") }
            if source.isStore {
                switch stores[source] ?? .notConnected {
                case .notConnected, .waiting: return String(localized: "library.badge.signin", defaultValue: "Sign In")
                case .expired: return "!"
                case .connected: break
                }
            }
            let n = games(in: item).count
            return n > 0 ? String(n) : nil
        }
    }

    // MARK: Sidebar

    private func hasGames(_ source: GameSource) -> Bool { allGames.contains { $0.source == source } }

    private func isInSidebar(_ source: GameSource) -> Bool {
        if source == .installer { return hasGames(source) }
        guard source.isStore else { return true }
        return stores[source, default: .notConnected] != .notConnected || sidebarStores[source] ?? hasGames(source)
    }

    var sidebarSources: [GameSource] { GameSource.offered.filter(isInSidebar) }

    var addableStores: [GameSource] {
        let stores = GameSource.offered.filter { $0.isStore && !isInSidebar($0) }
        return stores.filter { !$0.isExperimental } + stores.filter(\.isExperimental)
    }

    func addStore(_ store: GameSource) {
        if store.isStore { sidebarStores[store] = true }
        selection = .source(store)
    }

    func canRemoveStore(_ source: GameSource) -> Bool {
        source.isStore && stores[source, default: .notConnected] == .notConnected
    }

    func removeStore(_ store: GameSource) {
        if canRemoveStore(store) { sidebarStores[store] = false }
    }

    // Stricter than Remove: the + only takes back what holds nothing yet
    func canUnaddStore(_ store: GameSource) -> Bool { canRemoveStore(store) && !hasGames(store) }

    func unaddStore(_ store: GameSource) {
        if canUnaddStore(store) { removeStore(store) }
    }

    func storeMenu(added: Set<String>) -> [AddMenuItem] {
        let stores = GameSource.offered.filter { $0 != .installer }
        return (stores.filter { !$0.isExperimental } + stores.filter(\.isExperimental)).compactMap { store in
            guard let badge = PlatformBadge.source(store) else { return nil }
            let state: AddMenuItem.State
            if !isInSidebar(store) {
                state = .available
            } else {
                state = added.contains(store.id) && canUnaddStore(store) ? .added : .locked
            }
            return AddMenuItem(id: store.id, name: store.name, badge: badge,
                               note: store.isExperimental ? String(localized: "Experimental") : nil, state: state)
        }
    }

    private func keepSourceInSidebar() {
        if case .source(let source) = selection, !isInSidebar(source) { selection = .all }
    }

    func isSignedIn(_ item: SidebarItem) -> Bool {
        guard case .source(let source) = item else { return false }
        return (stores[source] ?? .notConnected).isSignedIn
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

    // MARK: Steam app IDs

    // Installer games whose record has no app ID ask Steam once each, so their
    // covers can come down and the ID is kept on the record for later lookups.
    // Callers gate this on the online-lookups privacy choice.
    func resolveInstallerAppIDs(lookup: SteamLookup, allowed: Bool) async {
        guard allowed else { return }
        var changed = false
        let installs = installsFolder, previous = previousInstalls
        let records = await Task.detached { InstalledGames.all(in: installs, previous: previous) }.value
        for var record in records where record.appID == nil {
            guard let found = await lookup.match(for: record.name) else { continue }
            record.appID = found.appID
            guard let folder = GameFolder.of(slug: record.id, in: installs) else { continue }
            let saving = record
            do {
                try await Task.detached { try InstalledGames.save(saving, in: folder) }.value
                changed = true
            } catch {
                AppLog.note("could not save the app ID for \(record.id): \(error.localizedDescription)")
            }
        }
        if changed { await reloadInstalledGames() }
    }

    // A Steam cover pick fills a missing app ID on the install record; a known one stays.
    func adoptAppID(_ appID: Int, for game: Game) {
        guard let folder = GameFolder.of(game, in: installsFolder),
              var record = InstalledGames.record(in: folder), record.appID == nil else { return }
        record.appID = appID
        do {
            try InstalledGames.save(record, in: folder)
        } catch {
            AppLog.note("could not save the app ID for \(record.id): \(error.localizedDescription)")
            return
        }
        showInstalledGames(InstalledGames.all(in: installsFolder, previous: previousInstalls))
    }

    // MARK: Games location

    // Every games location, scanned off the main actor. With forgetUnused, an earlier location left without games is dropped.
    func reloadInstalledGames(forgetUnused: Bool = false) async {
        let installs = installsFolder, previous = previousInstalls
        let (records, unused) = await Task.detached {
            (InstalledGames.all(in: installs, previous: previous), forgetUnused ? GameFolder.unused(previous) : [])
        }.value
        // A location changed meanwhile has its own scan
        guard installs == installsFolder else { return }
        showInstalledGames(records)
        guard !unused.isEmpty else { return }
        GameFolder.forget(unused, defaults: defaults)
        previousInstalls = GameFolder.previous(defaults)
    }

    // New installer and store games go to folder; games already installed stay where they are and keep playing.
    // Returns why the folder can't be used, if it can't.
    func changeGamesLocation(to folder: URL, app: URL = Bundle.main.bundleURL) async -> String? {
        if let problem = await Task.detached(operation: { GameFolder.problem(with: folder, app: app) }).value {
            return problem
        }
        GameFolder.choose(folder, leaving: installsFolder, defaults: defaults)
        installsFolder = GameFolder.current(defaults)
        previousInstalls = GameFolder.previous(defaults)
        onGamesLocationChange?(installsFolder)
        await reloadInstalledGames()
        return nil
    }

    // A store game goes under the chosen games location; with none chosen it stays beside the store's own files.
    func storeGameFolder(_ source: GameSource, title: String, id: String) -> URL? {
        guard GameFolder.chosen(defaults) != nil else { return nil }
        return installsFolder.appending(path: GameFolder.storeGamesName, directoryHint: .isDirectory)
            .appending(path: source.id, directoryHint: .isDirectory)
            .appending(path: "\(GameFolder.slug(title))-\(StoreFolders.safe(id))", directoryHint: .isDirectory)
    }

    // The Steam pick's CDN cover becomes the game's stored override, so it wins
    // over every other source until the user clears it.
    @discardableResult
    func useSteamCover(_ item: SteamLookup.Item, for game: Game, covers: CoverStore) async -> Bool {
        guard let file = await covers.download(item.appID, .cover) else { return false }
        setCover(file, for: game.id)
        adoptAppID(item.appID, for: game)
        return true
    }

    func setup(for id: String) -> GameSetupChoice { choices.setups[id] ?? GameSetupChoice() }

    func setSetup(_ setup: GameSetupChoice, for id: String, tellSteam: Bool = true) {
        let setup = absorbLegacy(setup, for: id)
        choices.setups[id] = setup
        persist()
        if let game = game(id), game.source == .installer {
            applyInstallerSetup(setup, for: game)
        } else if tellSteam {
            self.tellSteam(id)
        }
    }

    func adoptSetups(_ updates: [String: GameSetupChoice]) {
        guard !updates.isEmpty else { return }
        let updates = updates.reduce(into: [String: GameSetupChoice]()) { $0[$1.key] = absorbLegacy($1.value, for: $1.key) }
        choices.setups.merge(updates) { _, new in new }
        persist()
        for (id, setup) in updates where game(id)?.source == .installer {
            applyInstallerSetup(setup, for: game(id)!)
        }
    }

    // Setups naming a replaced runner name its update; saved before they are shown, so a failed save changes nothing.
    func replaceRunnerInSetups(_ old: String, with new: String) throws -> [String] {
        let (updated, moved) = RunnerMigration.replacing(old, with: new, in: choices)
        guard !moved.isEmpty else { return [] }
        try store.save(updated)
        choices = updated
        return moved
    }

    // A setup rewritten in place, with nothing passed on to Steam
    func replaceChoice(_ setup: GameSetupChoice, for id: String) {
        choices.setups[id] = setup
        persist()
    }

    private func persist() {
        do {
            try store.save(choices)
        } catch {
            problem = String(localized: "Cartouche couldn’t save your library choices: \(error.localizedDescription)")
        }
    }

    private func keepSelectionVisible() {
        let list: [Game]
        switch screen {
        case .grid(let sections): list = sections.flatMap(\.games)
        default: list = []
        }
        if let current = selectedGameID, list.contains(where: { $0.id == current }) { return }
        selectedGameID = list.first?.id
    }

    var recentlyPlayed: [Game] {
        Array(allGames.filter { $0.lastPlayed != nil && isVisible($0) }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(3))
    }
}
