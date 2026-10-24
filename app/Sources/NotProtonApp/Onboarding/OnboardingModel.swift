// The Stores step's Steam row may ask macOS for App Management; the Permissions
// step asks only what earlier choices made necessary, one sentence each.

import AppKit
import Foundation
import Observation
import RetroArchKit

struct RunnerOffer: Sendable {
    var build: @Sendable () -> RunnerManifest.Build?
    var isInstalled: @Sendable (String) -> Bool
    var install: @Sendable (RunnerManifest.Build) async throws -> Void

    static var live: RunnerOffer {
        RunnerOffer(
            build: { recommended(RunnerManifest.current()) },
            isInstalled: { WineRunnerInstaller.isInstalled($0) },
            install: { _ = try await WineRunnerInstaller.install($0) })
    }

    // A pending pin is never offered: its download could only fail.
    static func recommended(_ manifest: RunnerManifest) -> RunnerManifest.Build? {
        RunnerUpdate.latestCartouche(in: manifest)
    }
}

struct ConsoleSetup: Sendable {
    var added: @Sendable () async -> [String]
    var add: @Sendable (String) async throws -> Void
    var bios: @Sendable (Console) -> BIOSStatus
    var biosFolder: URL

    static func live(paths: RetroArchPaths, source: CoreSource = .qa, session: URLSession = .shared) -> ConsoleSetup {
        let shelf = ConsoleShelf(paths: paths, cores: CoreManager(paths: paths, source: source, session: session))
        return ConsoleSetup(
            added: { await shelf.added().map(\.id) },
            add: { try await shelf.add($0) },
            bios: { BIOSChecker(paths: paths).status(for: $0) },
            biosFolder: paths.bios)
    }
}

// Restarting Steam waits for the client to quit; it never runs on the main actor.
struct SteamControl: Sendable {
    var isRunning: @Sendable () -> Bool
    var restart: @Sendable () async -> Bool

    static var inert: SteamControl {
        SteamControl(isRunning: { false }, restart: { false })
    }

    static var live: SteamControl {
        SteamControl(
            isRunning: { SteamBundle.isRunning },
            restart: {
                let stopped = await Task.detached {
                    try? SteamBundle.stopClient(step: String(localized: "Restart Steam"))
                }.value
                guard stopped != nil else { return false }
                let opened = try? Shell.run("/usr/bin/open", ["-g", "-j", SupportPaths.Steam.app.path(percentEncoded: false), "--args", "-silent"])
                return opened?.succeeded == true
            })
    }
}

@MainActor
@Observable
final class OnboardingModel {

    enum RunnerPhase: Equatable {
        case none
        case notInstalled
        case downloading
        case installed
        case failed(String)
    }

    private(set) var state: OnboardingState
    private(set) var resumed = false
    var isPresented = false
    private(set) var findings: MacFindings?
    private(set) var machine: PerformanceReport.Mac?
    private(set) var runner: RunnerManifest.Build?
    private(set) var shelf: [String] = []
    private(set) var consoleProblem: String?
    private(set) var restartingSteam = false
    private(set) var steamRestarted: Bool?
    private(set) var movingStorage = false
    private(set) var storageProblem: String?

    let steamStep: SteamStep
    @ObservationIgnored let store: OnboardingStore
    @ObservationIgnored let scan: MacScan
    @ObservationIgnored let runners: RunnerOffer
    @ObservationIgnored let consoles: ConsoleSetup
    @ObservationIgnored let folders: GameFolders
    @ObservationIgnored let privacy: PrivacyChoices
    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored let setup: SetupTasks
    @ObservationIgnored let permissionFlow: PermissionFlow?
    @ObservationIgnored let stores: StoreCenter?
    @ObservationIgnored let controls: ControlsCenter?
    @ObservationIgnored private var steamStartTask: Task<Void, Never>?
    @ObservationIgnored var steam: SteamControl
    @ObservationIgnored var isRemovable: @Sendable (URL) -> Bool
    @ObservationIgnored var openURL: @MainActor (URL) -> Void
    @ObservationIgnored var play: @MainActor (Game) -> Void = { _ in }

    init(
        store: OnboardingStore = OnboardingStore(),
        scan: MacScan = .live,
        runners: RunnerOffer = .live,
        consoles: ConsoleSetup,
        steamStep: SteamStep,
        folders: GameFolders,
        privacy: PrivacyChoices,
        library: LibraryModel,
        setup: SetupTasks = SetupTasks(),
        permissions: PermissionCenter? = nil,
        stores: StoreCenter? = nil,
        controls: ControlsCenter? = nil,
        steam: SteamControl = .inert,
        isRemovable: @escaping @Sendable (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.volumeIsRemovableKey]))?.volumeIsRemovable ?? false
        }
    ) {
        self.store = store
        self.scan = scan
        self.runners = runners
        self.consoles = consoles
        self.steamStep = steamStep
        self.folders = folders
        self.privacy = privacy
        self.library = library
        self.setup = setup
        permissionFlow = permissions.map { PermissionFlow(center: $0) }
        self.stores = stores
        self.controls = controls
        self.steam = steam
        self.isRemovable = isRemovable
        openURL = { NSWorkspace.shared.open($0) }
        state = store.load() ?? OnboardingState()
        steamStep.beforeInstall = { [weak self] in
            guard let self else { return }
            self.steamStep.waitingForWine = self.setup.runner.working
            defer { self.steamStep.waitingForWine = false }
            while self.setup.runner.working { try await Task.sleep(for: .milliseconds(100)) }
            if let problem = self.setup.runner.problem {
                throw StepFailure(step: WineRunnerInstaller.step, detail: problem)
            }
        }
        steamStep.didSetUp = { [weak self] in
            self?.steamRestarted = nil
            self?.startSteamAfterSetup()
        }
        setup.didFinish = { [weak self] task in
            guard let self else { return }
            if task == "runner" {
                self.state.runnerRequested = false
                self.startSteamAfterSetup()
            }
            if task == "toolkit" { self.state.toolkitImage = nil }
            if task.hasPrefix("core:") {
                let id = String(task.dropFirst(5))
                self.state.coreRequests.removeAll { $0 == id }
            }
            self.save()
        }
    }

    var step: OnboardingStep { state.step }

    var isDue: Bool { !state.finished }

    func presentIfDue() {
        guard isDue else { return }
        resumed = state.step != .welcome
        isPresented = true
    }

    func reopen(on route: ScreenRoute) {
        guard route.screen == "onboarding", let step = route.detail.flatMap({ OnboardingStep.route($0) }) else { return }
        state.finished = false
        state.step = step
        save()
        resumed = false
        isPresented = true
    }

    func runAgain() {
        startOver()
        isPresented = true
    }

    func startOver() {
        steamStartTask?.cancel()
        steamStartTask = nil
        steamRestarted = nil
        let previous = state
        state = OnboardingState()
        state.addedConsoles = previous.addedConsoles
        state.runnerRequested = previous.runnerRequested
        state.coreRequests = previous.coreRequests
        state.toolkitImage = previous.toolkitImage
        resumed = false
        save()
        Task { await prepare() }
    }

    func retrySetup() {
        if setup.runner.problem != nil { startRunnerIfNeeded(force: true) }
        for (id, status) in setup.cores where status.problem != nil { setup.retryCore(id) }
        if let path = state.toolkitImage, setup.toolkit.problem != nil {
            importToolkitImage(URL(filePath: path))
        }
    }

    func prepare() async {
        if machine == nil { machine = await Task.detached { PerformanceReport.Mac.current() }.value }
        if findings == nil { findings = await scan.run() }
        prepareRunner()
        shelf = await consoles.added()
        pickFoundConsoles()
        offerFoundFolders()
        restoreSetupTasks()
    }

    func restoreSetupTasks() {
        prepareRunner()
        if state.runnerRequested { startRunnerIfNeeded(force: true) }
        setup.startCores(state.coreRequests)
        if let image = state.toolkitImage, !toolkitDetected {
            setup.importToolkitImage(URL(filePath: image))
        }
    }

    // MARK: Moving between steps

    func next() {
        let current = state.step
        guard let next = current.next else { return finish() }
        switch current {
        case .windowsGames:
            startRunnerIfNeeded()
        case .consoles:
            applyConsoles()
        case .permissions:
            applyStorage()
        case .ready:
            break
        default:
            break
        }
        go(to: next)
    }

    func back() {
        if let previous = state.step.previous { go(to: previous) }
    }

    func skip() {
        guard state.step.skippable, let next = state.step.next else { return }
        go(to: next)
    }

    func skipAll() {
        finish()
    }

    func finish() {
        startSteamAfterSetup()
        state.finished = true
        save()
        resumed = false
        isPresented = false
    }

    private func go(to step: OnboardingStep) {
        state.step = step
        resumed = false
        save()
        if step == .ready { Task { await refreshShelf() } }
    }

    private func save() {
        store.save(state)
    }

    private func refreshShelf() async {
        shelf = await consoles.added()
    }

    // MARK: Windows games

    var canContinue: Bool {
        switch state.step {
        case .stores: steamStep.canContinue
        default: true
        }
    }

    var runnerPhase: RunnerPhase {
        guard let build = runner else { return .none }
        let status = setup.runner
        if status.working { return .downloading }
        if status.done { return .installed }
        if let problem = status.problem { return .failed(problem) }
        return runners.isInstalled(build.id) ? .installed : .notInstalled
    }

    var wantsRunner: Bool {
        get { state.wantsRunner }
        set { state.wantsRunner = newValue; save() }
    }

    func prepareRunner() {
        runner = runners.build()
    }

    // The runner row or Continue may start it; the download + first boot run in
    // SetupTasks and keep going after the sheet closes.
    func startRunnerIfNeeded(force: Bool = false) {
        guard let build = runner, force || state.wantsRunner else { return }
        state.runnerRequested = true
        save()
        setup.startRunner(build, alreadyInstalled: runners.isInstalled(build.id))
    }

    func downloadRunner() async {
        startRunnerIfNeeded(force: true)
        while setup.runner.working { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: D3DMetal / Game Porting Toolkit

    // Detected at the scan or already copied into the runners folder
    var toolkitDetected: Bool {
        setup.toolkit.done || !(findings?.portingToolkit.isEmpty ?? true)
    }

    var toolkitReady: Bool {
        (setup.toolkit.done || findings?.portingToolkit.contains(where: \.ready) == true) && !setup.toolkit.working
    }

    var toolkitStatus: String {
        if setup.toolkit.working { return setup.toolkit.detail ?? String(localized: "Working") }
        if let problem = setup.toolkit.problem { return problem }
        if let version = setup.toolkitVersion {
            return String(localized: "D3DMetal ready — Game Porting Toolkit \(version)")
        }
        if let found = findings?.portingToolkit.first {
            return found.ready ? String(localized: "D3DMetal ready — \(found.name)") : found.name
        }
        return String(localized: "D3DMetal needs Apple's Game Porting Toolkit")
    }

    func importToolkitImage(_ url: URL) {
        state.toolkitImage = url.plainPath
        save()
        setup.importToolkitImage(url)
    }

    func openToolkitHelp() {
        openURL(PortingToolkitSource.howToGetIt)
    }

    // MARK: Stores

    private func startSteamAfterSetup() {
        guard steamStep.phase == .done, steamStartTask == nil, steamRestarted != true else { return }
        steamStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.steamStartTask = nil }
            while self.setup.runner.working {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard self.setup.runner.problem == nil else { return }
            await self.restartSteamNow()
        }
    }

    func restartSteamNow() async {
        guard !restartingSteam else { return }
        restartingSteam = true
        steamRestarted = nil
        steamRestarted = await steam.restart()
        restartingSteam = false
    }

    var steamLibraryGames: Int { library.steam.games.count }

    // An empty library says what brings the games in: Steam opened once Cartouche is in it
    var steamLibraryDetail: String {
        switch steamLibraryGames {
        case 0 where steamStep.phase == .done:
            String(localized: "Waiting for Steam to load your games.")
        case 0:
            String(localized: "Set up Cartouche in Steam, then open Steam to bring your games in.")
        case 1:
            String(localized: "1 game in the library")
        default:
            String(localized: "\(steamLibraryGames) games in the library")
        }
    }

    var storeTiles: [GameSource] { StoreCenter.stores }

    func connection(_ store: GameSource) -> StoreConnection {
        stores?.connection(store) ?? .notConnected
    }

    func beginSignIn(_ store: GameSource) {
        guard let stores else { return }
        Task { await stores.beginSignIn(store) }
    }

    // MARK: Consoles

    var picked: Set<String> { Set(state.consoles) }

    func isPicked(_ console: Console) -> Bool { picked.contains(console.id) || shelf.contains(console.id) }

    func isAdded(_ console: Console) -> Bool { shelf.contains(console.id) || setup.cores[console.id]?.done == true || (state.addedConsoles.contains(console.id) && !state.coreRequests.contains(console.id)) }

    func toggle(_ console: Console) {
        guard !shelf.contains(console.id) else { return }
        if let i = state.consoles.firstIndex(of: console.id) {
            state.consoles.remove(at: i)
        } else {
            state.consoles.append(console.id)
        }
        state.consolesChosen = true
        save()
    }

    var consolesToAdd: [Console] {
        ConsoleCatalog.all.filter { picked.contains($0.id) && !isAdded($0) }
    }

    var biosNotes: [BIOSStatus] {
        ConsoleCatalog.all
            .filter { isPicked($0) && $0.bios != .none }
            .map { consoles.bios($0) }
    }

    func foundGames(_ console: Console) -> Int { findings?.consoleGames[console.id] ?? 0 }

    // Continue on Consoles: picks are kept, cores download in the background.
    private func applyConsoles() {
        let ids = consolesToAdd.map(\.id)
        for id in ids where !state.addedConsoles.contains(id) {
            state.addedConsoles.append(id)
        }
        state.coreRequests = Array(Set(state.coreRequests + ids)).sorted()
        setup.startCores(ids)
        applyFolders()
        save()
    }

    // The old footer button: start the downloads and wait for them before moving on.
    func addConsoles() async {
        let ids = consolesToAdd.map(\.id)
        applyConsoles()
        consoleProblem = nil
        while setup.cores.values.contains(where: \.working) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        consoleProblem = ids.lazy.compactMap { self.setup.cores[$0]?.problem }.first
        shelf = await consoles.added()
        if consoleProblem == nil { next() }
    }

    private func pickFoundConsoles() {
        guard !state.consolesChosen, state.consoles.isEmpty, let found = findings?.consoleGames, !found.isEmpty else { return }
        state.consoles = ConsoleCatalog.all.map(\.id).filter { found[$0] != nil }
        save()
    }

    // MARK: Watched folders

    struct FolderRow: Identifiable, Equatable {
        let url: URL
        let found: FoundFolder?
        var id: String { url.plainPath }
    }

    var folderRows: [FolderRow] {
        let found = findings?.folders ?? []
        let added = state.folders.keys.sorted().filter { path in !found.contains { $0.id == path } }
        var rows = found.map { FolderRow(url: $0.url, found: $0) }
            + added.map { FolderRow(url: URL(filePath: $0, directoryHint: .isDirectory), found: nil) }
        if let rom = state.romFolder, !rows.contains(where: { $0.id == rom }) {
            rows.append(FolderRow(url: URL(filePath: rom, directoryHint: .isDirectory), found: nil))
        }
        return rows
    }

    func keepsFolder(_ id: String) -> Bool { state.folders[id] ?? true }

    func setKeepsFolder(_ id: String, _ keep: Bool) {
        state.folders[id] = keep
        save()
    }

    func addFolder(_ folder: URL) {
        state.folders[folder.plainPath] = true
        save()
    }

    var romFolder: String? { state.romFolder }

    func chooseRomFolder(_ folder: URL) {
        state.romFolder = folder.plainPath
        save()
    }

    private func offerFoundFolders() {
        var changed = false
        for folder in findings?.folders ?? [] where state.folders[folder.id] == nil {
            state.folders[folder.id] = true
            changed = true
        }
        if changed { save() }
    }

    private func applyFolders() {
        for (path, keep) in state.folders.sorted(by: { $0.key < $1.key }) where keep {
            folders.add(URL(filePath: path, directoryHint: .isDirectory))
        }
        if let rom = state.romFolder {
            folders.add(URL(filePath: rom, directoryHint: .isDirectory))
        }
    }

    // MARK: Controller

    var controllerConnected: Bool {
        if let controls { return !controls.monitor.controllers.isEmpty }
        return !(findings?.controllers.isEmpty ?? true)
    }

    var padDiagramState: PadState { controls?.diagramState ?? .idle }

    var padFamily: PadFamily {
        state.padGlyphs.flatMap(PadFamily.init(rawValue:))
            ?? controls?.monitor.primary?.family
            ?? .playStation
    }

    func setPadGlyphs(_ family: PadFamily?) {
        state.padGlyphs = family?.rawValue
        save()
    }

    var padPreset: ControllerLayout.Preset {
        state.padPreset.flatMap(ControllerLayout.Preset.init(rawValue:)) ?? .standard
    }

    var padPresets: [ControllerLayout.Preset] { [.standard, .southpaw, .swapAB] }

    func setPadPreset(_ preset: ControllerLayout.Preset) {
        state.padPreset = preset.rawValue
        save()
    }

    var controllerKeys: Bool {
        get { state.controllerKeys }
        set { state.controllerKeys = newValue; save() }
    }

    // The live diagram reads input while the Controller step is up
    func setDiagramVisible(_ visible: Bool) {
        controls?.diagramVisible = visible
    }

    // MARK: Permissions, storage, privacy

    // Only what earlier choices made necessary — never the whole list.
    var neededPermissions: [Permission] {
        var list: [Permission] = []
        if setup.runner.started || !setup.cores.isEmpty {
            list.append(.notifications)
        }
        if controllerConnected && state.controllerKeys {
            list.append(.accessibility)
        }
        if state.watchDownloads {
            list.append(.downloads)
        }
        if let folder = state.gamesFolder,
           isRemovable(URL(filePath: folder, directoryHint: .isDirectory)) {
            list.append(.removableVolumes)
        }
        return list
    }

    var watchDownloads: Bool {
        get { state.watchDownloads }
        set { state.watchDownloads = newValue; save() }
    }

    func permissionState(_ permission: Permission) -> PermissionState {
        permissionFlow?.center.state(permission) ?? .notAsked
    }

    func ask(_ permission: Permission) {
        permissionFlow?.start(permission, context: .onboarding) { _ in }
    }

    // MARK: Games location

    var gamesLocation: URL {
        state.gamesFolder.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? library.installsFolder
    }

    var gamesLocationIsExternal: Bool {
        state.gamesFolder != nil && isRemovable(gamesLocation)
    }

    func chooseGamesFolder(_ folder: URL) {
        state.gamesFolder = folder.plainPath
        save()
    }

    // Existing games keep their paths and stay in the library; only new installs use the chosen folder.
    private func applyStorage() {
        guard let path = state.gamesFolder else { return }
        let target = URL(filePath: path, directoryHint: .isDirectory)
        guard target.plainPath != library.installsFolder.plainPath else { return }
        movingStorage = true
        storageProblem = nil
        let library = library
        Task { [weak self] in
            let problem = await library.changeGamesLocation(to: target)
            self?.movingStorage = false
            self?.storageProblem = problem
        }
    }

    // MARK: Ready

    struct ReadyTask: Identifiable, Equatable {
        enum State: Equatable { case working, done, failed }
        let id: String
        let title: String
        var detail: String
        var state: State
    }

    var readyTasks: [ReadyTask] {
        var list: [ReadyTask] = []
        if let build = runner, setup.runner.started || runners.isInstalled(build.id) {
            let status = setup.runner
            list.append(ReadyTask(
                id: "runner",
                title: build.title,
                detail: status.done || (!status.started && runners.isInstalled(build.id))
                    ? String(localized: "Ready")
                    : status.problem ?? status.detail ?? String(localized: "Waiting"),
                state: status.done || (!status.started && runners.isInstalled(build.id)) ? .done : (status.problem != nil ? .failed : .working)))
        }
        for console in ConsoleCatalog.all where isAdded(console) || setup.cores[console.id] != nil {
            if let status = setup.cores[console.id] {
                list.append(ReadyTask(
                    id: "core-\(console.id)",
                    title: console.name,
                    detail: status.done
                        ? String(localized: "Core ready")
                        : status.problem ?? status.detail ?? String(localized: "Waiting"),
                    state: status.done ? .done : (status.problem != nil ? .failed : .working)))
            } else {
                list.append(ReadyTask(
                    id: "core-\(console.id)",
                    title: console.name,
                    detail: String(localized: "Core ready"),
                    state: .done))
            }
        }
        if setup.toolkit.started || toolkitDetected {
            let status = setup.toolkit
            let ready = toolkitReady
            list.append(ReadyTask(
                id: "d3dmetal",
                title: "D3DMetal",
                detail: toolkitStatus,
                state: status.working ? .working : (ready ? .done : (status.problem != nil ? .failed : .working))))
        }
        if findings?.steam != nil || steamLibraryGames > 0 {
            list.append(ReadyTask(
                id: "steam-library",
                title: String(localized: "Steam library"),
                detail: steamLibraryGames == 1
                    ? String(localized: "1 game in the library")
                    : String(localized: "\(steamLibraryGames) games in the library"),
                state: .done))
        }
        return list
    }

    var readyGame: Game? {
        let installed = library.allGames.filter { $0.installed && !library.isHidden($0.id) }
        let played = installed.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
        return played ?? installed.first
    }

    var readySummary: String {
        let steamGames = library.steam.games.count
        let consoleCount = Set(shelf + state.addedConsoles).count
        let games = steamGames == 1 ? String(localized: "1 Steam game") : String(localized: "\(steamGames) Steam games")
        let added = consoleCount == 1 ? String(localized: "1 console") : String(localized: "\(consoleCount) consoles")
        switch (steamGames > 0, consoleCount > 0) {
        case (true, true): return String(localized: "Your library has \(games) and \(added).")
        case (true, false): return String(localized: "Your library has \(games).")
        case (false, true): return String(localized: "Your library has \(added).")
        case (false, false): return String(localized: "Your library is ready for the games you add.")
        }
    }

    func playReadyGame() {
        guard let game = readyGame else { return }
        finish()
        play(game)
    }
}

enum OnboardingSteam {
    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    @MainActor
    static func install(through status: SystemStatus) async throws {
        try await install(through: status, replacingNotProton: false)
    }

    @MainActor
    static func replaceNotProton(through status: SystemStatus) async throws {
        try await install(through: status, replacingNotProton: true)
    }

    @MainActor
    static func repair(through status: SystemStatus) async throws {
        try await run(through: status) { await status.repairInSteam() }
    }

    @MainActor
    private static func install(through status: SystemStatus, replacingNotProton: Bool) async throws {
        try await run(through: status) {
            if replacingNotProton {
                await status.replaceNotProton()
            } else {
                await status.installIntoSteam()
            }
        }
    }

    @MainActor
    private static func run(through status: SystemStatus, _ work: @MainActor () async -> Void) async throws {
        await status.refresh()
        await work()
        guard let failure = status.failure else { return }
        if status.failureRemedy == .appManagement {
            throw WriteRefused(path: SupportPaths.Steam.deployedDylib.path(percentEncoded: false))
        }
        throw Failed(errorDescription: failure)
    }
}
