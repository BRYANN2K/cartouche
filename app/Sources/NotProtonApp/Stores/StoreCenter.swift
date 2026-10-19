// Epic Games, GOG and Amazon Games in the library: who is signed in, the games
// each account owns, the downloads, and playing. The library window, Settings >
// Accounts and the sign-in window all read and drive this one object.

import AppKit
import Foundation
import InstallerKit
import Observation

// A download, update, verify or import, one at a time
@MainActor
@Observable
final class StoreJob: Identifiable {

    enum Kind: Equatable, Sendable {
        case install, update, verify, importing

        var label: String {
            switch self {
            case .install: String(localized: "Downloading")
            case .update: String(localized: "Updating")
            case .verify: String(localized: "Verifying")
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

struct StoreActivity: Equatable, Sendable {
    let gameID: String
    let title: String
    let label: String
    let fraction: Double
    let waiting: Int
}

// The sign-in window's state
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

    static let stores: [GameSource] = [.epic, .gog, .amazon]

    private(set) var connections: [GameSource: StoreConnection] = [:]
    private(set) var games: [GameSource: [StoreGame]] = [:]
    private(set) var installed: [String: StoreInstalledGame] = [:]
    private(set) var jobs: [StoreJob] = []
    private(set) var refreshing: Set<GameSource> = []
    private(set) var playing: Set<String> = []
    var signIn: SignInSession?
    var problem: String?

    @ObservationIgnored let folders: StoreFolders
    @ObservationIgnored let secrets: StoreSecrets
    @ObservationIgnored private(set) var adapters: [GameSource: any StoreAdapter] = [:]
    @ObservationIgnored weak var library: LibraryModel?
    // Opens the sign-in window; the app sets it, tests leave it
    @ObservationIgnored var showSignIn: @MainActor () -> Void = {}
    // What Cartouche does once a game starts, from Settings > General
    @ObservationIgnored var afterLaunch: @MainActor () -> Void = {}
    @ObservationIgnored var runners: URL = SupportPaths.runners
    @ObservationIgnored var backends: URL = BackendInstaller.folder
    // The variables a game gets besides Wine's own, never the app's environment
    @ObservationIgnored var gameEnvironment: [String: String] = [
        "HOME": SupportPaths.home.path(percentEncoded: false), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
    ]
    @ObservationIgnored var now: () -> Date = { Date() }
    // The compatibility data's Steam App ID for a title, for the estimate; set by the app
    @ObservationIgnored var matchAppID: @MainActor (String) -> Int? = { _ in nil }
    // When the last sign-in finished and when its games were listed, for the 15 second promise
    @ObservationIgnored private(set) var lastSignIn: (finished: Date, listed: Date?)?

    convenience init(folders: StoreFolders, vault: any TokenVault, files: StoreClientFiles, library: LibraryModel?) {
        let secrets = folders.secrets(vault: vault)
        self.init(sharing: secrets, folders: folders, files: files, library: library, adapters: [
            .epic: EpicAdapter(context: folders.context(.epic, files: files, secrets: secrets)),
            .gog: GOGAdapter(context: folders.context(.gog, files: files, secrets: secrets)),
            .amazon: AmazonAdapter(context: folders.context(.amazon, files: files, secrets: secrets)),
        ])
    }

    // The adapters run their clients with the same secrets, so overlapping runs share one copy of the tokens
    init(sharing secrets: StoreSecrets, folders: StoreFolders, files: StoreClientFiles, library: LibraryModel?,
         adapters: [GameSource: any StoreAdapter]) {
        self.folders = folders
        self.library = library
        self.secrets = secrets
        self.adapters = adapters
    }

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

    // Accounts from the vault, games from the last listing, then a fresh listing
    func start(refresh: Bool = true) async {
        await secrets.sweep()
        for store in Self.stores {
            games[store] = folders.loadLibrary(store)
            for record in folders.loadRecords(store) { installed[record.gameID] = record }
            let secret = try? await secrets.secret(store)
            if let secret, let adapter = adapters[store] {
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
        connections[store] = .waiting
        publish()
        showSignIn()
        do {
            // A new sign-in starts from no tokens: nile refuses to register over a saved one
            try await secrets.forget(store)
            let page = try await adapter.signInPage()
            if signIn?.store == store { signIn?.state = .waiting(page) }
        } catch {
            fail(store, error)
        }
    }

    // Called by the sign-in window for every address it reaches. True once the
    // store handed over its code, and the window can close.
    @discardableResult
    func reached(_ url: URL, pageText: String? = nil) -> Bool {
        guard let session = signIn, case .waiting = session.state, let adapter = adapters[session.store],
              let code = adapter.code(at: url, pageText: pageText) else { return false }
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
        signIn = nil
        if connections[session.store] == .waiting { connections[session.store] = .notConnected }
        publish()
    }

    private func fail(_ store: GameSource, _ error: Error) {
        if signIn?.store == store { signIn?.state = .failed(error.localizedDescription) }
        if connections[store] == .waiting { connections[store] = .notConnected }
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
        guard let adapter = adapters[store], connection(store).isSignedIn, !refreshing.contains(store) else { return }
        refreshing.insert(store)
        defer { refreshing.remove(store) }
        do {
            var list = try await adapter.library()
            // Art already found stays; the rest is looked up in the background
            let known = Dictionary((games[store] ?? []).map { ($0.id, $0.art) }, uniquingKeysWith: { a, _ in a })
            for i in list.indices where list[i].art == nil { list[i].art = known[list[i].id] ?? nil }
            games[store] = list
            try? folders.saveLibrary(list, for: store)
            if case .expired(let account) = connection(store) { connections[store] = .connected(account: account) }
            if lastSignIn != nil, lastSignIn?.listed == nil { lastSignIn?.listed = now() }
            publish()
            await findArt(store)
        } catch {
            handle(error, store: store)
        }
    }

    private func findArt(_ store: GameSource) async {
        guard let adapter = adapters[store] else { return }
        let missing = (games[store] ?? []).filter { $0.art == nil }
        guard !missing.isEmpty else { return }
        var found: [String: URL] = [:]
        for game in missing.prefix(200) {
            if let url = await adapter.artURL(game) { found[game.id] = url }
        }
        guard !found.isEmpty, var list = games[store] else { return }
        for i in list.indices { if let url = found[list[i].id] { list[i].art = url } }
        games[store] = list
        try? folders.saveLibrary(list, for: store)
        publish()
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

    // The library's games for the stores, each installed or not
    func libraryGames() -> [Game] {
        var out: [Game] = []
        for store in Self.stores {
            var seen: Set<String> = []
            for game in games[store] ?? [] {
                let id = "\(store.id):\(game.id)"
                seen.insert(id)
                out.append(Self.game(store, game, installed: installed[id], appID: matchAppID(game.title)))
            }
            // Installed games stay even when the store's list is not at hand
            for record in installed.values where record.store == store.id && !seen.contains(record.gameID) {
                out.append(Self.game(store, StoreGame(id: record.id, title: record.title), installed: record, appID: matchAppID(record.title)))
            }
        }
        return out
    }

    static func game(_ store: GameSource, _ game: StoreGame, installed: StoreInstalledGame?, appID: Int? = nil) -> Game {
        var out = Game(id: "\(store.id):\(game.id)", source: store, name: game.title, installed: installed != nil)
        out.artwork = game.art
        out.compatAppID = appID
        return out
    }

    func publish() {
        guard let library else { return }
        for store in Self.stores { library.stores[store] = connection(store) }
        library.otherGames.removeAll { $0.source.isStore }
        library.otherGames += libraryGames()
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

    func install(_ game: Game) {
        guard let adapter = adapters[game.source], let storeGame = storeGame(game), job(for: game.id) == nil else { return }
        let folder = folders.gameFolder(game.source, title: storeGame.title, id: storeGame.id)
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

    func uninstall(_ game: Game) async {
        guard let adapter = adapters[game.source], let record = installed[game.id], !playing.contains(game.id) else { return }
        do {
            if !record.imported { try await adapter.uninstall(record.id, install: record.install) }
            try? FileManager.default.removeItem(at: record.folder)
            folders.remove(record)
            installed[game.id] = nil
            publish()
        } catch {
            handle(error, store: game.source)
        }
    }

    func stop(_ job: StoreJob) {
        job.task?.cancel()
        if job.phase == .waiting {
            jobs.removeAll { $0 === job }
            pump()
        }
    }

    // A game folder another launcher installed
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
            self?.jobs.removeAll { $0 === next && $0.phase == .done }
            self?.pump()
        }
    }

    // MARK: Playing

    // The runner, backend and translation the game's setup resolves to. Store games run
    // under Rosetta, as Windows installs do.
    func setup(for game: Game) -> GameSetup? {
        library?.resolution(for: game).setup
    }

    func play(_ game: Game) {
        guard let adapter = adapters[game.source], let record = installed[game.id], !playing.contains(game.id) else { return }
        guard let setup = setup(for: game), let runner = setup.runner else {
            problem = String(localized: "Set up a runner in Settings > Compatibility to play \(game.name).")
            return
        }
        guard let wine = InstallRunners.wine(for: runner, runners: runners) else {
            problem = String(localized: "\(runner.kind.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup.")
            return
        }
        playing.insert(game.id)
        let offline = (library?.isOffline ?? false) || { if case .expired = connection(game.source) { return true }; return false }()
        Task {
            do {
                try await run(game, record: record, adapter: adapter, setup: setup, wine: wine, offline: offline)
            } catch {
                handle(error, store: game.source)
            }
            playing.remove(game.id)
        }
    }

    private func run(_ game: Game, record: StoreInstalledGame, adapter: any StoreAdapter, setup: GameSetup, wine: WineRunner,
                     offline: Bool) async throws {
        var record = record
        try await makePrefix(record.prefix, wine: wine)
        StoreGameEnvironment.prepare(setup.backend, prefix: record.prefix, backends: backends)

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
        let env = StoreGameEnvironment.make(wine: wine, prefix: record.prefix, setup: setup, launch: launch,
                                            backends: backends, base: gameEnvironment)
        let command = StoreGameEnvironment.command(wine: wine, launch: launch, environment: env)
        let companion = offline ? nil : try? await adapter.companion(record.id)
        let log = record.folder.appending(path: "game.log")
        let companionLog = record.folder.appending(path: "companion.log")

        let body: @Sendable () async throws -> Void = { [wine, env] in
            let helper = try companion.map { try StoreProcess($0, output: companionLog) }
            let process = try StoreProcess(command, output: log)
            await MainActor.run { self.afterLaunch() }
            _ = await process.wait()
            // The game may have left its launcher behind and kept running in the prefix
            await StoreCenter.waitForWine(wine, environment: env)
            helper?.stop()
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
        if installed[record.gameID] != nil { keep(record) }
    }

    // A fresh prefix the first time the game starts, made by the runner of its setup
    private func makePrefix(_ prefix: URL, wine: WineRunner) async throws {
        guard !FileManager.default.fileExists(atPath: prefix.appending(path: "system.reg").path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let launch = WineInstall.createPrefix(runner: wine, prefix: prefix, base: gameEnvironment)
        let output = try await ClientProcess.run(ClientCommand(executable: URL(filePath: launch.executable), arguments: launch.arguments,
                                                               environment: launch.environment))
        guard output.succeeded else {
            throw StoreError.failed(String(localized: "The prefix could not be created (status \(output.status))."))
        }
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: gameEnvironment)
        await Self.waitForWine(wine, environment: env)
    }

    // wineserver -w returns once every process of the prefix has exited
    nonisolated static func waitForWine(_ wine: WineRunner, environment: [String: String]) async {
        _ = try? await ClientProcess.run(ClientCommand(executable: wine.server, arguments: ["-w"], environment: environment))
    }
}

extension StoreConnection {
    // Connected or expired: the account is known, and its games are listed
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

extension StoreSecrets {
    // Drops a store's tokens from the vault and from disk
    func forget(_ store: GameSource) throws {
        if let folder = folders[store] {
            for (_, url) in Self.files(in: folder, matching: patterns[store] ?? []) { try? FileManager.default.removeItem(at: url) }
        }
        try vault.delete(store)
    }

    // Names the account of the tokens a sign-in just saved
    func remember(account: String, for store: GameSource) throws {
        setAccount(account, for: store)
        guard var secret = try vault.read(store) else { throw StoreError.failed(String(localized: "The sign-in left no login token.")) }
        secret.account = account
        try vault.write(secret, for: store)
    }
}
