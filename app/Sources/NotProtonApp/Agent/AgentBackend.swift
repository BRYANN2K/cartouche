import AppKit
import Foundation
import InstallerKit
import RetroArchKit

// The app itself as an agent backend: every tool lands on the same models the
// window uses — LibraryModel for the library and setup, ConsoleCenter for
// console play, InstallCenter for installs. Nothing is duplicated here; the
// backend only adapts calls and roots.
@MainActor
final class AgentLiveBackend: AgentBackend {

    let library: LibraryModel
    let consoleCenter: ConsoleCenter
    let installs: InstallCenter
    let compat: CompatibilityModel
    let controlsCenter: ControlsCenter
    let stores: StoreCenter
    let performance: PerformanceStore
    let cleaner = InstallerCleanup()

    // The folders an agent may read beyond Cartouche's own: watched game
    // folders, every installed game's folder, Steam prefix roots. Computed
    // per call so a game or folder added after launch is granted at once.
    var roots: AgentRoots {
        var roots = AgentRoots(
            support: SupportPaths.support, logs: SupportPaths.logs,
            installs: GameFolder.installs, retroarch: consoleCenter.paths.root,
            caches: SupportPaths.winetricksDownloads.deletingLastPathComponent())
        roots.granted = (consoleCenter.folderList?.folders ?? [])
            + library.allGames.compactMap { library.installFolder(of: $0) }
            + PrefixStore.libraries().map(\.compatdata)
        return roots
    }

    // Indirection for tests: opening URLs, runner installs, folder copy.
    var open: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var installRunnerBody: (@MainActor (String) async throws -> Void)?

    init(library: LibraryModel, consoles: ConsoleCenter, installs: InstallCenter,
         compat: CompatibilityModel, controls: ControlsCenter, stores: StoreCenter,
         performance: PerformanceStore = PerformanceStore()) {
        self.library = library
        self.consoleCenter = consoles
        self.installs = installs
        self.compat = compat
        self.controlsCenter = controls
        self.stores = stores
        self.performance = performance
    }

    // MARK: Library

    func games() -> [Game] { library.allGames }
    func game(_ id: String) -> Game? { library.game(id) }
    func isFavorite(_ id: String) -> Bool { library.isFavorite(id) }
    func isHidden(_ id: String) -> Bool { library.isHidden(id) }
    func setFavorite(_ id: String, on: Bool) {
        if library.isFavorite(id) != on { library.toggleFavorite(id) }
    }
    func hide(_ id: String, on: Bool) {
        if on { library.hide(id) } else { library.unhide(id) }
    }
    func installFolder(of game: Game) -> URL? { library.installFolder(of: game) }

    // MARK: Setup

    func setupChoice(for id: String) -> GameSetupChoice { library.setup(for: id) }
    func setSetup(_ choice: GameSetupChoice, for id: String) {
        library.setSetup(choice, for: id)
    }
    func resolution(for game: Game) -> GameSetupResolver.Resolution { library.resolution(for: game) }
    func graphicsChoices(for game: Game) -> [GraphicsBackend] { library.graphicsChoices(for: game) }
    func translationChoices(for game: Game) -> [GameSetupChoice.Translation] {
        library.translationChoices(for: game)
    }
    func hasMacBuild(_ game: Game) -> Bool { library.hasMacBuild(game) }

    // MARK: Runners

    func runners() -> [Runner] { library.runners }
    func refreshRunners() async -> [Runner] {
        let registry = await Task.detached { RunnerRegistry.refresh(free: .standard) }.value
        library.runners = registry.runners
        library.backendAvailability = await Task.detached {
            BackendAvailability.current(registry: registry, manifest: .current())
        }.value
        return registry.runners
    }
    func installRunner(_ id: String) async throws {
        if let body = installRunnerBody { try await body(id); return }
        guard let build = RunnerManifest.current().build(id: id) else {
            throw AgentToolError("no downloadable runner \"\(id)\"; CrossOver and the "
                + "Porting Toolkit are set up from Settings > Compatibility")
        }
        _ = try await WineRunnerInstaller.install(build)
        _ = await refreshRunners()
    }
    func repairRunner(_ id: String) async throws {
        if let body = installRunnerBody { try await body(id); return }
        let problems = WineRunnerInstaller.verify(id)
        if problems.isEmpty { return }
        try await installRunner(id)
    }
    func defaultRunner() -> String? { library.setupDefaults.runnerID }
    func setDefaultRunner(_ id: String) {
        var defaults = library.setupDefaults
        defaults.runnerID = id
        defaults.save(library.defaults)
    }
    func backendAvailability() -> BackendAvailability { library.backendAvailability }

    // MARK: Launch and quit

    func launch(_ game: Game) async throws {
        if let console = game.console {
            try await launchConsole(console, slot: nil, resume: false)
            return
        }
        if let appID = game.steamAppID, game.source == .steam {
            open(URL(string: "steam://rungameid/\(appID)")!)
            return
        }
        if game.source.isStore {
            guard stores.record(game.id) != nil else {
                throw AgentToolError("\(game.name) is not installed")
            }
            stores.play(game)
            if let problem = stores.problem { throw AgentToolError(problem) }
            return
        }
        if installedGame(for: game) != nil {
            GameActionRunner.launchInstaller(game)
            return
        }
        throw AgentToolError("\(game.name) is not installed")
    }

    func launchStore(_ url: String) async throws {
        guard let url = URL(string: url) else { throw AgentToolError("bad store link") }
        open(url)
    }

    func quit(_ game: Game, force: Bool) async throws {
        if game.console != nil {
            await consoleCenter.quit()
            return
        }
        guard force else {
            throw AgentToolError("only force_quit stops a Wine game: there is no gentle way")
        }
        if game.steamAppID != nil, game.source == .steam {
            throw AgentToolError("Steam games quit from Steam or the game's own menu")
        }
        guard let installed = installedGame(for: game),
              let wine = wineRunner(for: installed.runnerID) else {
            throw AgentToolError("\(game.name) is not running under Cartouche")
        }
        let server = wine.server.path(percentEncoded: false)
        let prefix = installed.prefix
        _ = try await Task.detached {
            try Shell.run(server, ["-k"], environment: [
                "WINEPREFIX": URL(filePath: prefix).path(percentEncoded: false)])
        }.value
    }

    private struct ReportLine: Encodable {
        var game: String
        var verdict: String
        var note: String
        var time: String
    }

    func reportResult(_ game: Game, verdict: String, note: String?) throws {
        try JSONLines.append(
            ReportLine(game: game.id, verdict: verdict, note: note ?? "",
                       time: AgentTools.stamp.string(from: Date())),
            to: roots.support.appending(path: "agents/reports.jsonl"))
    }

    // MARK: Installs

    func analyze(_ path: URL) async throws -> InstallerAnalysis {
        try await Analyzer.analyze(path, tool: Innoextract.path())
    }

    func startInstall(_ request: InstallRequest, inputs: InstallInputs) -> UUID {
        let job = InstallJob(request: request, inputs: inputs)
        installs.enqueue(job)
        return job.id
    }

    func installJobs() -> [InstallJob] { installs.jobs }
    func installJob(_ id: UUID) -> InstallJob? { installs.jobs.first { $0.id == id } }

    func retryInstall(_ job: InstallJob, fixes: [RetryFix]) throws {
        installs.retry(job, fixes: fixes)
    }

    func stopInstall(_ job: InstallJob) throws { installs.stop(job) }

    func finishInstall(_ job: InstallJob, exe: URL) throws {
        _ = try installs.finish(job, exe: exe, showInSteam: false)
    }

    func cleanupInstaller(_ request: InstallRequest) throws -> Int64 {
        try cleaner.run(files: request.installerFiles, folder: request.source)
        return request.installerBytes
    }

    func copyInstallerToInternal(_ source: URL) async throws -> URL {
        let folder = roots.support.appending(path: "installers").appending(path: source.lastPathComponent)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder)
        // The copy of a multi-GB installer does not belong on the main actor.
        try await Task.detached {
            try FileManager.default.copyItem(at: source, to: folder)
        }.value
        return folder
    }

    // MARK: Prefix tools

    // The prefix and the Wine to use: a Steam game's compatdata prefix, an
    // installer game's own pfx.
    private func winePrefix(for game: Game) throws -> (prefix: URL, env: [String: String], wine: WineRunner?) {
        if let installed = installedGame(for: game) {
            let prefix = URL(filePath: installed.prefix)
            guard let runner = library.runners.first(where: { $0.id == installed.runnerID }),
                  let wine = InstallRunners.wine(for: runner) else {
                throw AgentToolError("the runner \(installed.runnerID) is not set up")
            }
            return (prefix, WineInstall.environment(runner: wine, prefix: prefix, inputs: nil,
                                                    base: ProcessInfo.processInfo.environment), wine)
        }
        guard let appID = game.steamAppID else { throw AgentToolError("\(game.name) has no prefix") }
        guard let prefix = PrefixStore.all().first(where: { $0.appID == String(appID) }) else {
            throw AgentToolError("\(game.name) has no prefix; launch it once first")
        }
        let chosen = try PrefixTools.resolvedTool(step: "the agent's command", for: prefix)
        let runner = SupportPaths.clonedRoot(forBuild: chosen.build)
        return (prefix.pfx,
                PrefixTools.environment(prefix: prefix, runner: runner, flavor: chosen.tool.flavor), nil)
    }

    func runWinetricks(_ game: Game, verbs: [String]) async throws -> URL {
        if let installed = installedGame(for: game) {
            let prefix = URL(filePath: installed.prefix)
            guard let runner = library.runners.first(where: { $0.id == installed.runnerID }),
                  let wine = InstallRunners.wine(for: runner) else {
                throw AgentToolError("the runner \(installed.runnerID) is not set up")
            }
            let log = URL(filePath: installed.prefix).deletingLastPathComponent()
                .appending(path: PrefixTools.winetricksLogName)
            try await installs.engine.winetricks(verbs, prefix, wine, log)
            return log
        }
        guard let appID = game.steamAppID,
              let prefix = PrefixStore.all().first(where: { $0.appID == String(appID) }) else {
            throw AgentToolError("\(game.name) has no prefix; launch it once first")
        }
        return try await PrefixTools.winetricks(verbs, in: prefix)
    }

    // The prefix a tool may look at — drive_c and all. nil when the game has
    // no usable prefix yet.
    func prefixFolder(_ game: Game) -> URL? {
        try? winePrefix(for: game).prefix
    }

    // wine reg takes seconds on a cold prefix; it cannot block the main actor.
    func registryGet(_ game: Game, key: String, value: String) async throws -> String {
        let (_, env, _) = try winePrefix(for: game)
        guard let loader = env["WINELOADER"] else { throw AgentToolError("no Wine loader") }
        return try await Task.detached {
            try Shell.check(loader, ["reg", "query", key, "/v", value], environment: env)
        }.value
    }

    func registrySet(_ game: Game, key: String, value: String, data: String, type: String) async throws {
        let (_, env, _) = try winePrefix(for: game)
        guard let loader = env["WINELOADER"] else { throw AgentToolError("no Wine loader") }
        _ = try await Task.detached {
            try Shell.check(loader, ["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"],
                            environment: env)
        }.value
    }

    func runInPrefix(_ game: Game, exe: URL, args: [String]) async throws {
        let (prefix, env, _) = try winePrefix(for: game)
        guard AgentScan.contains(exe, in: roots.allowed + [prefix]) else {
            throw AgentToolError("the program must be inside the game's prefix or Cartouche's folders")
        }
        guard let loader = env["WINELOADER"] else { throw AgentToolError("no Wine loader") }
        try Shell.detach(loader, [exe.path(percentEncoded: false)] + args, environment: env)
    }

    // MARK: Consoles

    func consoles() -> [Console] { ConsoleCatalog.all }
    func addedConsoles() -> [Console] { consoleCenter.added }
    func consoleGames() -> [ConsoleGame] { consoleCenter.games }
    func consoleGame(_ id: String) -> ConsoleGame? { consoleCenter.game(id) }

    func addConsole(_ id: String) async throws {
        await consoleCenter.add([id])
        if let problem = consoleCenter.problem { throw AgentToolError(problem) }
    }

    func removeConsole(_ id: String) async throws {
        await consoleCenter.remove(id)
        if let problem = consoleCenter.problem { throw AgentToolError(problem) }
    }

    func biosStatus(_ consoleID: String) async -> BIOSStatus? {
        guard let console = ConsoleCatalog.console(consoleID) else { return nil }
        let paths = consoleCenter.paths
        return await Task.detached { BIOSChecker(paths: paths).status(for: console) }.value
    }

    func states(_ game: ConsoleGame) async -> [SaveState] { await consoleCenter.states(for: game) }

    func launchConsole(_ game: ConsoleGame, slot: Int?, resume: Bool) async throws {
        await consoleCenter.play(game.id, slot: slot, resume: resume)
        if let problem = consoleCenter.problem { throw AgentToolError(problem) }
    }

    func consolePlaying() -> Playing? { consoleCenter.playing }

    func setConsoleSetup(_ id: String, _ change: @escaping @Sendable (inout ConsoleGameSetup) -> Void) async {
        await consoleCenter.setSetup(id, change)
    }

    private func player() throws -> ConsolePlayer {
        guard let player = consoleCenter.runner as? ConsolePlayer else {
            throw AgentToolError("RetroArch is not running a game")
        }
        return player
    }

    func consoleSaveState(_ slot: Int) async throws {
        guard let session = try await player().session else { throw AgentToolError("nothing is playing") }
        try await session.saveState(slot: slot)
    }

    func consoleLoadState(_ slot: Int) async throws {
        guard let session = try await player().session else { throw AgentToolError("nothing is playing") }
        try await session.loadState(slot: slot)
    }

    func consoleScreenshot() async throws -> Data {
        guard let session = try await player().session else { throw AgentToolError("nothing is playing") }
        return try await session.screenshot()
    }

    func consoleSwapDisc(_ disc: Int) async throws {
        guard let runner = consoleCenter.runner else { throw AgentToolError("nothing is playing") }
        try await runner.setDisc(disc)
    }

    func consoleQuit() async throws { await consoleCenter.quit() }

    func identifyFile(_ url: URL) async throws -> Identification? {
        await consoleCenter.identifier.identify(url)
    }

    func addConsoleGames(_ games: [ConsoleGame]) async throws {
        _ = await consoleCenter.addGames(games)
    }

    func rescanFolders() async { await consoleCenter.rescanFolders() }

    // MARK: Controls

    func controllers() -> [ControllerInfo] { controlsCenter.monitor.controllers }

    func gameControls(_ id: String) -> GameControls {
        guard let game = library.game(id) else { return GameControls() }
        return controlsCenter.controls(for: game)
    }

    func setGameControls(_ new: GameControls, for id: String) async throws {
        guard let game = library.game(id) else { throw AgentToolError("no game \"\(id)\"") }
        await controlsCenter.update(game) { $0 = new }
        if let problem = controlsCenter.problem { throw AgentToolError(problem) }
    }

    func controlsAccessibility() -> Bool {
        controlsCenter.permissions.state(.accessibility) == .allowed
    }

    // MARK: Diagnostics and system

    func sessions(_ game: Game) -> [StoredSession] {
        (try? performance.sessions(appID: game.steamAppID)) ?? []
    }

    func compatRecord(_ game: Game) -> CompatRecord? {
        game.steamAppID.flatMap { compat.record(appID: $0) }
    }

    func macEntry(_ game: Game) -> MacGamingDBEntry? {
        game.steamAppID.flatMap { compat.macReports[$0] }
    }

    func gpuStrength() -> [String: Double] { compat.data?.gpuStrength ?? [:] }

    func logFile(_ source: String, for game: Game?) -> URL? {
        switch source {
        case "app": return AppLog.file
        case "console": return consoleCenter.paths.logs.appending(path: "retroarch.log")
        case "installer":
            guard let game else { return nil }
            // A finished job links back to the installed game; a running one
            // is matched by title.
            let slug = String(game.id.dropFirst("installer:".count))
            if let job = installs.jobs.last(where: { $0.game?.id == slug || $0.title == game.name }) {
                return installLogFile(job)
            }
            if let installed = installedGame(for: game) {
                let file = URL(filePath: installed.prefix)
                    .deletingLastPathComponent().appending(path: "install.log")
                return FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
                    ? file : nil
            }
            return nil
        default:
            guard let game else { return nil }
            if let installed = installedGame(for: game) {
                return URL(filePath: installed.prefix).deletingLastPathComponent()
                    .appending(path: "wine-output.log")
            }
            guard let appID = game.steamAppID else { return nil }
            let launchers = SupportPaths.launchers.appending(path: String(appID))
            switch source {
            case "wine": return launchers.appending(path: "cartouche-wine.log")
            case "launch": return launchers.appending(path: "cartouche-run.log")
            default: return nil
            }
        }
    }

    func installLogFile(_ job: InstallJob) -> URL? {
        guard let folder = job.folder else { return nil }
        for name in ["install.log", "wine-output.log", "prefix.log"] {
            let file = folder.root.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        }
        return nil
    }

    func diskFree(at url: URL) -> Int64? { Disk.freeBytes(at: url) }

    private func installedGame(for game: Game) -> InstalledGame? {
        guard game.source == .installer else { return nil }
        let slug = String(game.id.dropFirst("installer:".count))
        return InstalledGames.all().first { $0.id == slug }
    }

    private func wineRunner(for runnerID: String) -> WineRunner? {
        library.runners.first { $0.id == runnerID }.flatMap { InstallRunners.wine(for: $0) }
    }
}
