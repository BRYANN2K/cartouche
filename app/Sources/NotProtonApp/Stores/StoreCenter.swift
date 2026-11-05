
import AppKit
import Foundation
import InstallerKit
import Observation

@MainActor
@Observable
final class StoreJob: Identifiable {

    enum Kind: Equatable, Sendable {
        case install, update, verify, uninstall, importing

        var label: String {
            switch self {
            case .install: String(localized: "Downloading")
            case .update: String(localized: "Updating")
            case .verify: String(localized: "Verifying")
            case .uninstall: String(localized: "Removing")
            case .importing: String(localized: "Importing")
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case waiting, running, done
        case failed(String)
    }

    let id = UUID()
    let gameID: String
    let title: String
    let kind: Kind
    var fraction: Double = 0
    var phase: Phase = .waiting
    @ObservationIgnored var task: Task<Void, Never>?

    init(gameID: String, title: String, kind: Kind) {
        self.gameID = gameID
        self.title = title
        self.kind = kind
    }
}

// A running or failed "Preparing Windows environment" boot for one store game.
struct StoreBoot {
    let boot: WineBootstrap.Boot
    var problem: String?
}

struct StoreActivity: Equatable, Sendable {
    let gameID: String
    let title: String
    let label: String
    let fraction: Double
    let waiting: Int
}

struct SignInSession: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case preparing
        case waiting(SignInPage)
        case finishing
        case failed(String)
    }

    let store: GameSource
    var state: State
}

@MainActor
@Observable
final class StoreCenter {

    static let stores: [GameSource] = [.epic, .gog, .amazon, .ea, .ubisoft]

    private(set) var connections: [GameSource: StoreConnection] = [:]
    private(set) var games: [GameSource: [StoreGame]] = [:]
    private(set) var installed: [String: StoreInstalledGame] = [:]
    private(set) var jobs: [StoreJob] = []
    private(set) var refreshing: Set<GameSource> = []
    private(set) var playing: Set<String> = []
    // A game's "Preparing Windows environment" boot, running or failed — the panel shows it.
    private(set) var boots: [String: StoreBoot] = [:]
    var signIn: SignInSession?
    var problem: String?
    // What a launcher is doing now; nil falls back to whether its exe is there.
    var launcherActivity: [GameSource: LauncherState] = [:]

    @ObservationIgnored let folders: StoreFolders
    @ObservationIgnored let secrets: StoreSecrets
    @ObservationIgnored private(set) var adapters: [GameSource: any StoreAdapter] = [:]
    @ObservationIgnored weak var library: LibraryModel?
    @ObservationIgnored var showSignIn: @MainActor () -> Void = {}
    @ObservationIgnored var afterLaunch: @MainActor () -> Void = {}
    // Pre-sign-in connections go to .waiting and are restored on cancel or failure, so a cancelled sign-in is not a sign-out.
    @ObservationIgnored private var priorConnections: [GameSource: StoreConnection] = [:]
    @ObservationIgnored private var processes: [String: [StoreProcess]] = [:]
    @ObservationIgnored private var noArt: [GameSource: [String: Date]] = [:]
    @ObservationIgnored var runners: URL = SupportPaths.runners
    @ObservationIgnored var backends: URL = BackendInstaller.folder
    // The variables a game gets besides Wine's own, never the app's environment
    @ObservationIgnored var gameEnvironment: [String: String] = SetupEnvironment.base
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var matchAppID: @MainActor (String) -> Int? = { _ in nil }
    // Sign-in finish and library-list times, for the 15 second promise.
    @ObservationIgnored private(set) var lastSignIn: (finished: Date, listed: Date?)?
    // The launcher-session watcher while a viaLauncher sign-in is up, and its pacing.
    @ObservationIgnored private var sessionWatch: Task<Void, Never>?
    @ObservationIgnored var sessionPollInterval: TimeInterval = 2
    @ObservationIgnored var sessionPollTimeout: TimeInterval = 15 * 60
    @ObservationIgnored var launcherInstalls: [GameSource: Task<Void, Never>] = [:]
    @ObservationIgnored var fetchInstaller: @Sendable (LauncherInstaller, URL, @escaping @Sendable (Double) -> Void) async throws -> URL = LauncherInstaller.fetch
    @ObservationIgnored var runInstaller: @Sendable (StoreLauncher, URL) async throws -> Void = { try await $0.install(from: $1) }

    convenience init(folders: StoreFolders, vault: any TokenVault, files: StoreClientFiles, library: LibraryModel?) {
        let secrets = folders.secrets(vault: vault)
        let wine: @Sendable () async throws -> WineRunner = { throw StoreError.notSignedIn }
        self.init(sharing: secrets, folders: folders, files: files, library: library, adapters: [
            .epic: EpicAdapter(context: folders.context(.epic, files: files, secrets: secrets)),
            .gog: GOGAdapter(context: folders.context(.gog, files: files, secrets: secrets)),
            .amazon: AmazonAdapter(context: folders.context(.amazon, files: files, secrets: secrets)),
            .ea: EAAdapter(backing: LauncherBackedStore(folders: folders, secrets: secrets, wine: wine,
                                                      run: ProcessLauncherRun(log: folders.launcher(.ea).appending(path: "launcher.log")))),
            .ubisoft: UbisoftAdapter(backing: LauncherBackedStore(folders: folders, secrets: secrets, wine: wine,
                                                                run: ProcessLauncherRun(log: folders.launcher(.ubisoft).appending(path: "launcher.log")))),
        ])
    }

    // The adapters run their clients with the same secrets, so overlapping runs share one copy of the tokens
    init(sharing secrets: StoreSecrets, folders: StoreFolders, files: StoreClientFiles, library: LibraryModel?,
         adapters: [GameSource: any StoreAdapter]) {
        self.folders = folders
        self.library = library
        self.secrets = secrets
        self.adapters = adapters
        wireLaunchers()
    }

    // The launcher's Wine is the runner a store game's install would pick: resolved at call
    // time, after the center's own `runners` and the library's list are known.
    private func wireLaunchers() {
        let wine: @Sendable () async throws -> WineRunner = { [weak self] in
            guard let self else { throw StoreError.failed(String(localized: "The store is gone.")) }
            return try await self.launcherWine()
        }
        let backend: @Sendable () async -> GraphicsBackend? = { [weak self] in await self?.launcherBackend() ?? nil }
        if var adapter = adapters[.ea] as? EAAdapter { adapter.backing.wine = wine; adapter.backing.backend = backend; adapters[.ea] = adapter }
        if var adapter = adapters[.ubisoft] as? UbisoftAdapter { adapter.backing.wine = wine; adapter.backing.backend = backend; adapters[.ubisoft] = adapter }
    }

    func launcherWine() throws -> WineRunner {
        if let runner = library?.installRunners.first, let wine = InstallRunners.wine(for: runner, runners: runners) {
            return wine
        }
        throw StoreError.failed(String(localized: "Set up a runner in Settings > Compatibility first."))
    }

    // The launcher's backend is the one an unconfigured store game's launch would pick
    // on the same runner (B11): the launcher parents the game, per-game choices of a
    // different backend only land when the launcher itself is the started process.
    func launcherBackend() -> GraphicsBackend? {
        guard let library else { return nil }
        return GameSetupResolver.resolve(GameSetupChoice(), defaults: library.setupDefaults,
                                         runners: library.runners, availability: library.backendAvailability,
                                         offered: library.installRunners).setup.backend
    }

    // Tests repoint an adapter's endpoints at the fixture server.
    func replace(_ adapter: any StoreAdapter, for store: GameSource) { adapters[store] = adapter }

    // Cartouche's own folders and the real Keychain
    static func live(library: LibraryModel) -> StoreCenter {
        let folders = StoreFolders(root: library.store.folder.appending(path: "stores", directoryHint: .isDirectory))
        let files = StoreClientFiles(root: folders.clients,
                                     downloads: SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/store-clients"))
        return StoreCenter(folders: folders, vault: KeychainVault(), files: files, library: library)
    }

    func adapter(_ store: GameSource) -> (any StoreAdapter)? { adapters[store] }

    func connection(_ store: GameSource) -> StoreConnection { connections[store] ?? .notConnected }

    // MARK: Start

    func start(refresh: Bool = true) async {
        await secrets.sweep()
        for store in Self.stores {
            games[store] = folders.loadLibrary(store)
            for record in folders.loadRecords(store) { installed[record.gameID] = record }
            noArt[store] = folders.loadArtMisses(store)
            adoptLauncherInstalls(store)
            // An unavailable adapter is never asked for its session: no vault read, no expiry check.
            if let adapter = adapters[store], adapter.isAvailable, let secret = try? await secrets.secret(store) {
                connections[store] = adapter.isExpired(secret, now: now()) ? .expired(account: secret.account) : .connected(account: secret.account)
            } else {
                connections[store] = .notConnected
            }
        }
        publish()
        guard refresh else { return }
        for store in Self.stores where connection(store).isSignedIn { await self.refresh(store) }
    }

    // MARK: Sign-in

    func beginSignIn(_ store: GameSource) async {
        guard let adapter = adapters[store] else { return }
        signIn = SignInSession(store: store, state: .preparing)
        if !connections.keys.contains(store) || connections[store] != .waiting {
            priorConnections[store] = connections[store] ?? .notConnected
        }
        connections[store] = .waiting
        publish()
        showSignIn()
        do {
            // Sign-in runs on an empty folder; saved tokens stay in the vault until the new session lands.
            let page = try await adapter.signInPage()
            if signIn?.store == store {
                signIn?.state = .waiting(page)
                if page.viaLauncher || page.timesOut { watch(store, adapter: adapter) }
            }
        } catch {
            fail(store, error)
        }
    }

    // A launcher-backed sign-in ends when the launcher's own cache names an account:
    // the watcher polls it until it does, the user cancels, or the timeout passes.
    private func watch(_ store: GameSource, adapter: any StoreAdapter) {
        sessionWatch?.cancel()
        sessionWatch = Task { [weak self] in
            guard let self else { return }
            let deadline = now().addingTimeInterval(sessionPollTimeout)
            while !Task.isCancelled {
                guard case .waiting = signIn?.state, signIn?.store == store else { return }
                if let account = await adapter.detectedSession() {
                    await finishSignIn(store, code: account)
                    return
                }
                guard now() < deadline else {
                    fail(store, StoreError.failed(String(localized: "No sign-in reached \(store.name) in time — try again.")))
                    return
                }
                try? await Task.sleep(for: .seconds(sessionPollInterval))
            }
        }
    }

    @discardableResult
    func reached(_ url: URL, pageText: String? = nil) -> Bool {
        guard let session = signIn, case .waiting = session.state, let adapter = adapters[session.store] else { return false }
        guard let code = adapter.code(at: url, pageText: pageText) else {
            guard let failure = adapter.signInFailure(at: url) else { return false }
            fail(session.store, StoreError.failed(failure))
            return true
        }
        signIn?.state = .finishing
        Task { await finishSignIn(session.store, code: code) }
        return true
    }

    func finishSignIn(_ store: GameSource, code: String) async {
        guard let adapter = adapters[store] else { return }
        do {
            let account = try await adapter.finishSignIn(code: code)
            try await secrets.remember(account: account, for: store)
            lastSignIn = (now(), nil)
            priorConnections[store] = nil
            connections[store] = .connected(account: account)
            signIn = nil
            library?.selection = .source(store)
            publish()
            await refresh(store)
            if lastSignIn?.listed == nil, games[store]?.isEmpty == false { lastSignIn?.listed = now() }
        } catch {
            fail(store, error)
        }
    }

    func cancelSignIn() {
        guard let session = signIn else { return }
        sessionWatch?.cancel()
        sessionWatch = nil
        signIn = nil
        if connections[session.store] == .waiting { connections[session.store] = priorConnections[session.store] ?? .notConnected }
        publish()
    }

    private func fail(_ store: GameSource, _ error: Error) {
        sessionWatch?.cancel()
        sessionWatch = nil
        if signIn?.store == store { signIn?.state = .failed(error.localizedDescription) }
        if connections[store] == .waiting { connections[store] = priorConnections[store] ?? .notConnected }
        publish()
    }

    func signOut(_ store: GameSource) async {
        try? await adapters[store]?.signOut()
        try? await secrets.forget(store)
        connections[store] = .notConnected
        publish()
    }

    // MARK: Library

    func refresh(_ store: GameSource) async {
        guard let adapter = adapters[store], adapter.isAvailable, connection(store).isSignedIn, !refreshing.contains(store) else { return }
        refreshing.insert(store)
        defer { refreshing.remove(store) }
        do {
            var list = try await adapter.library()
            let known = Dictionary((games[store] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in list.indices {
                guard let previous = known[list[i].id] else { continue }
                if list[i].art == nil { list[i].art = previous.art }
                if list[i].artFallback == nil { list[i].artFallback = previous.artFallback }
                list[i].header = previous.header
                list[i].screenshots = previous.screenshots
                list[i].downloadBytes = previous.downloadBytes
                list[i].diskBytes = previous.diskBytes
                list[i].detailsFetchedAt = previous.detailsFetchedAt
            }
            games[store] = list
            adoptLauncherInstalls(store)
            try? folders.saveLibrary(list, for: store)
            if case .expired(let account) = connection(store) { connections[store] = .connected(account: account) }
            if lastSignIn != nil, lastSignIn?.listed == nil { lastSignIn?.listed = now() }
            publish()
            await findArt(store)
        } catch {
            handle(error, store: store)
        }
    }

    func loadDetails(_ game: Game) async {
        guard game.source == .gog, library?.isOffline != true,
              let adapter = adapters[game.source], let current = storeGame(game) else { return }
        let ttl: TimeInterval = current.diskBytes == nil ? 300 : 7 * 24 * 3600
        if let date = current.detailsFetchedAt, now().timeIntervalSince(date) < ttl { return }
        let detailed = await adapter.details(current)
        guard var list = games[game.source], let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        list[index].header = detailed.header
        list[index].screenshots = detailed.screenshots
        list[index].downloadBytes = detailed.downloadBytes
        list[index].diskBytes = detailed.diskBytes
        list[index].detailsFetchedAt = detailed.detailsFetchedAt
        games[game.source] = list
        try? folders.saveLibrary(list, for: game.source)
        publish()
    }

    private func findArt(_ store: GameSource) async {
        guard let adapter = adapters[store] else { return }
        // A remembered miss is skipped for a month, then tried again.
        let stale = now().addingTimeInterval(-30 * 24 * 3600)
        var misses = noArt[store] ?? [:]
        let missing = (games[store] ?? []).filter { $0.art == nil && (misses[$0.id] ?? .distantPast) <= stale }
        guard !missing.isEmpty else { return }
        // The lookups can hit the network and take seconds; off the main actor.
        let found = await Self.findArt(for: Array(missing.prefix(200)), adapter: adapter)
        for game in missing where found[game.id] == nil { misses[game.id] = now() }
        for id in found.keys { misses[id] = nil }
        noArt[store] = misses
        try? folders.saveArtMisses(misses, for: store)
        guard !found.isEmpty, var list = games[store] else { return }
        for i in list.indices { if let url = found[list[i].id] { list[i].art = url } }
        games[store] = list
        try? folders.saveLibrary(list, for: store)
        publish()
    }

    // Six requests at a time: enough for a library page, gentle on GOG's API.
    private nonisolated static func findArt(for missing: [StoreGame], adapter: any StoreAdapter) async -> [String: URL] {
        await withTaskGroup(of: (String, URL?).self) { group in
            var found: [String: URL] = [:]
            var iterator = missing.makeIterator()
            for _ in 0..<6 {
                guard let game = iterator.next() else { break }
                group.addTask { (game.id, await adapter.artURL(game)) }
            }
            while let (id, url) = await group.next() {
                if let url { found[id] = url }
                if let game = iterator.next() { group.addTask { (game.id, await adapter.artURL(game)) } }
            }
            return found
        }
    }

    func handle(_ error: Error, store: GameSource) {
        if case StoreError.sessionExpired = error {
            expire(store)
        } else {
            problem = error.localizedDescription
        }
    }

    func expire(_ store: GameSource) {
        let account: String
        switch connection(store) {
        case .connected(let name), .expired(let name): account = name
        case .notConnected, .waiting: return
        }
        connections[store] = .expired(account: account)
        publish()
    }

    // A game the launcher finished installing on its own becomes a record too:
    // its folder holds only the pfx link to the launcher's prefix — Installed and
    // Play then reflect the launcher's truth, as an install through Cartouche would.
    private func adoptLauncherInstalls(_ store: GameSource) {
        for game in games[store] ?? [] {
            guard let path = game.installPath, LauncherFolder.folderBytes(path) >= 0 else { continue }
            let gameID = "\(store.id):\(game.id)"
            if var record = installed[gameID] {
                guard !record.imported, record.install.path != path else { continue }
                record.install.path = path
                try? folders.save(record)
                installed[gameID] = record
                continue
            }
            let folder = folders.gameFolder(store, title: game.title, id: game.id)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let link = folder.appending(path: "pfx")
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: folders.launcher(store).appending(path: "pfx"))
                keep(StoreInstalledGame(store: store.id, id: game.id, title: game.title,
                                        install: StoreInstall(path: path), folder: folder, installedAt: now()))
            } catch { continue }
        }
    }

    func libraryGames() -> [Game] {
        var out: [Game] = []
        for store in Self.stores {
            var seen: Set<String> = []
            for game in games[store] ?? [] {
                let id = "\(store.id):\(game.id)"
                seen.insert(id)
                out.append(Self.game(store, game, installed: installed[id], appID: matchAppID(game.title)))
            }
            for record in installed.values where record.store == store.id && !seen.contains(record.gameID) {
                out.append(Self.game(store, StoreGame(id: record.id, title: record.title), installed: record, appID: matchAppID(record.title)))
            }
        }
        return out
    }

    static func game(_ store: GameSource, _ game: StoreGame, installed: StoreInstalledGame?, appID: Int? = nil) -> Game {
        var out = Game(id: "\(store.id):\(game.id)", source: store, name: game.title, installed: installed != nil)
        out.artwork = game.art
        out.artworkFallback = game.artFallback
        out.mediaHeader = game.header
        out.mediaScreenshots = game.screenshots
        out.storageBytes = game.diskBytes
        out.storageEstimated = game.diskBytes != nil
        out.compatAppID = appID
        return out
    }

    func publish() {
        guard let library else { return }
        // One assignment: store by store, the sidebar would drop a selected store not yet updated.
        library.stores.merge(Self.stores.map { ($0, connection($0)) }) { _, new in new }
        // One assignment: two mutations would rebuild gamesByID without store games in between,
        // and keepSelectionVisible would drop the selection — and the game panel with it.
        library.otherGames = library.otherGames.filter { !$0.source.isStore } + libraryGames()
    }

    func record(_ gameID: String) -> StoreInstalledGame? { installed[gameID] }

    func storeGame(_ game: Game) -> StoreGame? {
        let id = String(game.id.dropFirst(game.source.id.count + 1))
        return games[game.source]?.first { $0.id == id } ?? installed[game.id].map { StoreGame(id: $0.id, title: $0.title) }
    }

    // MARK: Downloads

    var activity: StoreActivity? {
        guard let job = jobs.first(where: { $0.phase == .running }) else { return nil }
        return StoreActivity(gameID: job.gameID, title: job.title, label: job.kind.label, fraction: job.fraction,
                             waiting: jobs.filter { $0.phase == .waiting }.count)
    }

    func job(for gameID: String) -> StoreJob? {
        jobs.first { $0.gameID == gameID && ($0.phase == .running || $0.phase == .waiting) }
    }

    func install(_ game: Game, destination: URL? = nil) {
        guard let adapter = adapters[game.source], let storeGame = storeGame(game), job(for: game.id) == nil else { return }
        let folder = destination.map { StoreUninstall.folder(in: $0, title: storeGame.title, id: storeGame.id) } ?? library?.storeGameFolder(game.source, title: storeGame.title, id: storeGame.id) ?? folders.gameFolder(game.source, title: storeGame.title, id: storeGame.id)
        enqueue(StoreJob(gameID: game.id, title: game.name, kind: .install)) { [weak self] job in
            let install = try await adapter.install(storeGame, base: folder.appending(path: "game", directoryHint: .isDirectory)) { fraction in
                Task { @MainActor in job.fraction = fraction }
            }
            self?.keep(StoreInstalledGame(store: game.source.id, id: storeGame.id, title: storeGame.title, install: install,
                                          folder: folder, installedAt: Date()))
        }
    }

    func update(_ game: Game) {
        guard let adapter = adapters[game.source], var record = installed[game.id], job(for: game.id) == nil else { return }
        enqueue(StoreJob(gameID: game.id, title: game.name, kind: .update)) { [weak self] job in
            record.install = try await adapter.update(record.id, install: record.install) { fraction in
                Task { @MainActor in job.fraction = fraction }
            }
            self?.keep(record)
        }
    }

    func verify(_ game: Game) {
        guard let adapter = adapters[game.source], let record = installed[game.id], job(for: game.id) == nil else { return }
        enqueue(StoreJob(gameID: game.id, title: game.name, kind: .verify)) { job in
            try await adapter.verify(record.id, install: record.install) { fraction in
                Task { @MainActor in job.fraction = fraction }
            }
        }
    }

    // A job like the installs: the record and the files only come off once the store
    // confirms the removal — a cancelled job keeps both.
    func uninstall(_ game: Game) {
        guard let adapter = adapters[game.source], let record = installed[game.id],
              !playing.contains(game.id), job(for: game.id) == nil else { return }
        enqueue(StoreJob(gameID: game.id, title: game.name, kind: .uninstall)) { [weak self] _ in
            if record.imported {
                try await adapter.forget(record.id)
            } else {
                try await adapter.uninstall(record.id, install: record.install)
            }
            self?.forget(record)
        }
    }

    private func forget(_ record: StoreInstalledGame) {
        StoreUninstall.clear(record.folder)
        folders.remove(record)
        installed[record.gameID] = nil
        publish()
    }

    func stop(_ activity: StoreActivity) {
        guard let job = jobs.first(where: { $0.gameID == activity.gameID && $0.phase == .running }) else { return }
        stop(job)
    }

    func stop(_ job: StoreJob) {
        job.task?.cancel()
        if job.phase == .waiting {
            bodies[job.id] = nil
            jobs.removeAll { $0 === job }
            pump()
        }
    }

    // A failed job stays listed until it is dismissed or tried again.
    func dismiss(_ job: StoreJob) {
        guard case .failed(let reason) = job.phase else { return }
        jobs.removeAll { $0 === job }
        if problem == reason { problem = nil }
    }

    func importFolder(_ folder: URL, into store: GameSource) {
        guard let adapter = adapters[store] else { return }
        let library = games[store] ?? []
        enqueue(StoreJob(gameID: "\(store.id):import:\(folder.lastPathComponent)", title: folder.lastPathComponent, kind: .importing)) { [weak self, folders] _ in
            let (game, install) = try await adapter.importGame(at: folder, library: library)
            self?.keep(StoreInstalledGame(store: store.id, id: game.id, title: game.title, install: install,
                                          folder: folders.gameFolder(store, title: game.title, id: game.id),
                                          installedAt: Date(), imported: true))
        }
    }

    private func keep(_ record: StoreInstalledGame) {
        do {
            try folders.save(record)
        } catch {
            problem = error.localizedDescription
        }
        installed[record.gameID] = record
        publish()
    }

    private var bodies: [UUID: @MainActor (StoreJob) async throws -> Void] = [:]

    private func enqueue(_ job: StoreJob, _ body: @escaping @MainActor (StoreJob) async throws -> Void) {
        bodies[job.id] = body
        jobs.append(job)
        pump()
    }

    // One at a time: the clients each use every core and the whole connection
    private func pump() {
        guard !jobs.contains(where: { $0.phase == .running }), let next = jobs.first(where: { $0.phase == .waiting }),
              let body = bodies.removeValue(forKey: next.id) else { return }
        next.phase = .running
        let store = Self.stores.first { next.gameID.hasPrefix($0.id + ":") }
        next.task = Task { [weak self] in
            do {
                try await body(next)
                next.fraction = 1
                next.phase = .done
            } catch is CancellationError {
                next.phase = .failed(String(localized: "Stopped"))
            } catch {
                next.phase = Task.isCancelled ? .failed(String(localized: "Stopped")) : .failed(error.localizedDescription)
                if let store { self?.handle(error, store: store) }
            }
            self?.jobs.removeAll { $0 === next && ($0.phase == .done || Task.isCancelled) }
            self?.pump()
        }
    }

    // MARK: Playing

    // Store games run under Rosetta, as Windows installs do.
    func setup(for game: Game) -> GameSetup? {
        library?.resolution(for: game).setup
    }

    func play(_ game: Game) {
        guard let adapter = adapters[game.source], let record = installed[game.id],
              !playing.contains(game.id), job(for: game.id) == nil else { return }
        guard let runner = setup(for: game)?.runner else {
            problem = String(localized: "Set up a runner in Settings > Compatibility to play \(game.name).")
            return
        }
        guard let wine = InstallRunners.wine(for: runner, runners: runners) else {
            problem = String(localized: "\(runner.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup.")
            return
        }
        playing.insert(game.id)
        let offline = (library?.isOffline ?? false) || { if case .expired = connection(game.source) { return true }; return false }()
        Task {
            do {
                try await run(game, record: record, adapter: adapter, wine: wine, offline: offline)
            } catch {
                handle(error, store: game.source)
            }
            playing.remove(game.id)
        }
    }

    private func run(_ game: Game, record: StoreInstalledGame, adapter: any StoreAdapter, wine: WineRunner,
                     offline: Bool) async throws {
        // The folder's answers to DLSS and the anti-cheat land before the launch variables are resolved
        await library?.scan([(id: game.id, folder: record.install.path)])
        guard let setup = setup(for: game) else { return }
        let backends = self.backends, runners = self.runners
        let wine = try await Task.detached {
            try GraphicsRunner.prepare(wine, backend: setup.backend, backends: backends, runners: runners)
        }.value
        var record = record
        // Preparing Windows environment: the prefix's first boot finishes before anything launches.
        let boot = WineBootstrap.begin(wine: wine, prefix: record.prefix, base: gameEnvironment,
                                       log: record.folder.appending(path: "prefix.log"))
        if boot.prepares {
            boots[game.id] = StoreBoot(boot: boot)
            switch await boot.outcome.value {
            case .ready:
                boots[game.id] = nil
            case .stopped:
                boots[game.id] = nil
                return
            case .failed(let detail):
                boots[game.id]?.problem = detail
                return
            }
        }
        SetupEnvironment.prepare(setup.backend, prefix: record.prefix, backends: backends)

        let saves = adapter.capabilities.cloudSaves && !offline
        var locations: [SaveLocation] = []
        if saves {
            do {
                locations = try await adapter.saveLocations(record.id, install: record.install, prefix: record.prefix)
                record.saveStamps = try await adapter.syncSaves(record.id, locations: locations, direction: .download, stamps: record.saveStamps)
            } catch {
                if case StoreError.sessionExpired = error { expire(game.source) }
                AppLog.note("store: saves of \(record.gameID) not downloaded: \(error.localizedDescription)")
            }
        }

        var launch: StoreLaunch
        do {
            launch = try await adapter.launch(record.id, install: record.install, prefix: record.prefix, offline: offline)
        } catch StoreError.sessionExpired {
            // The session ended: the game still starts, offline, as the store allows
            expire(game.source)
            launch = try await adapter.launch(record.id, install: record.install, prefix: record.prefix, offline: true)
        }
        var env = SetupEnvironment.make(wine: wine, prefix: record.prefix, backend: setup.backend,
                                        environment: setup.environment, backends: backends, base: gameEnvironment)
        let prefixEnvironment = env
        let prefix = record.prefix
        let shared = launcherShared(record)
        // Per-game prefix writes stop the wineserver (msync/retina markers): never on a
        // launcher-owned prefix, whose server also serves the launcher and other games.
        if !shared {
            try await Task.detached {
                try AdvancedPrefixSettings.apply(wine: wine, prefix: prefix, environment: prefixEnvironment)
                CrashHandling.apply(wine: wine, prefix: prefix, environment: prefixEnvironment)
            }.value
        }
        // Only allowlisted store variables, and never the profile's own: legendary JSON must not set DYLD_* or
        // HOME on the native loader, nor give back the variables an anti-cheat had the launch remove.
        env.merge(launch.environment.filter {
            !OverlayLaunch.variables.contains($0.key) && $0.key != LaunchProfile.consentVariable
                && GameSetupResolver.isAllowed(name: $0.key, value: $0.value)
        }) { $1 }
        env = LaunchProfile.filteredEnvironment(env, dlss: library?.launchProfile(for: game).dlss ?? false)
        library?.noteLaunch(of: game, environment: env)
        let command = ClientCommand(executable: URL(filePath: WineInstall.rosetta[0]),
                                    arguments: Array(WineInstall.rosetta.dropFirst()) + [wine.loader.path(percentEncoded: false),
                                                                                        launch.executable.path(percentEncoded: false)] + launch.arguments,
                                    environment: env, currentDirectory: launch.workingDirectory)
        let companion = offline ? nil : try? await adapter.companion(record.id)
        let log = record.folder.appending(path: CrashLog.gameLog)
        let companionLog = record.folder.appending(path: "companion.log")
        let folder = record.folder

        let body: @Sendable () async throws -> Void = { [wine, env] in
            let helper = try companion.map { try StoreProcess($0, output: companionLog) }
            let process = try StoreProcess(command, output: log)
            await MainActor.run {
                self.processes[game.id] = [process] + (helper.map { [$0] } ?? [])
                self.afterLaunch()
            }
            _ = await process.wait()
            CrashLog.keep(log, in: folder)
            // The game may have left its launcher behind and kept running in the prefix —
            // except a shared launcher prefix, whose session must outlive this one run.
            if !shared {
                await StoreCenter.waitForWine(wine, environment: env)
            }
            helper?.stop()
            await MainActor.run { self.processes[game.id] = nil }
        }
        if companion != nil {
            try await secrets.using(game.source, body)
        } else {
            try await body()
        }

        if saves, !locations.isEmpty {
            do {
                record.saveStamps = try await adapter.syncSaves(record.id, locations: locations, direction: .upload, stamps: record.saveStamps)
            } catch {
                if case StoreError.sessionExpired = error { expire(game.source) }
                AppLog.note("store: saves of \(record.gameID) not uploaded: \(error.localizedDescription)")
            }
        }
        // Only this session's save stamps change; a concurrent update keeps its own record.
        if var live = installed[record.gameID] {
            live.saveStamps = record.saveStamps
            keep(live)
        }
    }

    // wineserver -w returns once every prefix process has exited; a stuck one is killed after five minutes.
    nonisolated static func waitForWine(_ wine: WineRunner, environment: [String: String]) async {
        await WineServer.wait(server: wine.server, env: environment, timeout: 300)
    }

    // A failed boot's second chance: Play prepares the prefix again (the booting marker is still there).
    func retryBoot(_ game: Game) {
        boots[game.id] = nil
        play(game)
    }

    // A failed boot's last resort: the prefix is wiped, then made from scratch —
    // never a launcher-shared prefix: wiping it would take the launcher's files with it.
    func recreateBoot(_ game: Game) {
        guard let record = installed[game.id] else { return }
        boots[game.id] = nil
        guard !launcherShared(record) else {
            play(game)
            return
        }
        let prefix = record.prefix
        guard Self.discard(prefix) == nil, FileManager.default.fileExists(atPath: prefix.path(percentEncoded: false)) else {
            play(game)
            return
        }
        // Could not be set aside: removed in place, off the main actor, before the new prefix is made
        Task {
            await Task.detached { try? FileManager.default.removeItem(at: prefix) }.value
            play(game)
        }
    }

    // One rename sets the folder aside at once; the slow removal of its files runs off the main actor
    @discardableResult
    nonisolated static func discard(_ folder: URL) -> Task<Void, Never>? {
        let aside = folder.deletingLastPathComponent()
            .appending(path: ".\(folder.lastPathComponent).discarded-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.moveItem(at: folder, to: aside)) != nil else { return nil }
        return Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: aside) }
    }

    // The record's prefix resolves through its pfx link: a launcher-backed game's is the
    // launcher's own, shared by every game it manages.
    func launcherShared(_ record: StoreInstalledGame) -> Bool {
        guard let store = Self.stores.first(where: { $0.id == record.store }) else { return false }
        let launcher = folders.launcher(store).appending(path: "pfx").standardizedFileURL
        return record.prefix.resolvingSymlinksInPath().standardizedFileURL == launcher
    }

    // wineserver -k whatever stayed in the prefix, so the session and its token files close —
    // never on a shared launcher prefix: that one wineserver owns the launcher and every
    // other running game, so stopping one game stops nothing at all there.
    func stopPlaying(_ game: Game) {
        let shared = installed[game.id].map(launcherShared) ?? false
        if let record = installed[game.id], !shared { WineBootstrap.stop(record.prefix) }
        boots[game.id] = nil
        guard playing.contains(game.id) else { return }
        if !shared {
            for process in processes[game.id] ?? [] { process.stop() }
        }
        guard let record = installed[game.id], !shared, let setup = setup(for: game), let runner = setup.runner,
              let wine = InstallRunners.wine(for: runner, runners: runners) else { return }
        let env = WineInstall.environment(runner: wine, prefix: record.prefix, inputs: nil, base: gameEnvironment)
        Task { await WineServer.kill(server: wine.server, env: env) }
    }
}

extension StoreConnection {
    var isSignedIn: Bool {
        switch self {
        case .connected, .expired: true
        case .notConnected, .waiting: false
        }
    }

    var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }
}
