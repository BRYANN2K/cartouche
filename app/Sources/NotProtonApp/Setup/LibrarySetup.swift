
import Foundation
import InstallerKit

extension LibraryModel {

    var setupDefaults: SetupDefaults { SetupDefaults.load(defaults) }

    var compatRequestsFile: URL { store.folder.appending(path: SupportPaths.compatRequests.lastPathComponent) }
    var setupsFolder: URL { store.folder.appending(path: SupportPaths.setups.lastPathComponent) }

    // An installer game never gets the choice: its folder only holds the Windows install.
    func hasMacBuild(_ game: Game) -> Bool {
        game.source != .installer && game.steamAppID.map(macBuilds.contains) ?? false
    }

    // Ready free Wine builds, Cartouche Wine first. Steam offers the same list.
    var installRunners: [Runner] { InstallRunners.choices(RunnerRegistry(runners: runners), manifest: runnerManifest) }

    // Install runners, then any other ready tool Steam already has. GPTK stays out:
    // it is the D3DMetal library, not a Wine loader.
    var steamRunners: [Runner] {
        var seen = Set<String>()
        let extra = runners.filter { runner in
            runner.isOffered || (runner.state == .ready && runner.isInstalled &&
                backendTools.contains { $0.build == runner.id })
        }
        return (installRunners + extra).filter { seen.insert($0.id).inserted }
    }

    func resolution(for game: Game, choice selected: GameSetupChoice? = nil) -> GameSetupResolver.Resolution {
        var choice = selected ?? setup(for: game.id)
        if game.source == .installer {
            // Rosetta, as installs run; defaults to the setup the install itself used
            choice.translation = .rosetta
            if choice.runnerID == nil { choice.runnerID = game.installRunnerID }
            if choice.graphics == nil { choice.graphics = game.installGraphics }
            return GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                             availability: backendAvailability, offered: installRunners)
        }
        if game.source.isStore { choice.translation = .rosetta }
        return GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                         availability: backendAvailability, hasMacBuild: hasMacBuild(game),
                                         offered: game.source.isStore ? installRunners : steamRunners)
    }

    func graphicsChoices(for game: Game) -> [GraphicsBackend] {
        let setup = resolution(for: game).setup
        guard let runner = setup.runner else { return [] }
        return BackendSupport.backends(for: runner, translation: setup.translation, availability: backendAvailability)
    }

    func graphicsChoices(for defaults: SetupDefaults) -> [GraphicsBackend] {
        let setup = GameSetupResolver.resolve(GameSetupChoice(), defaults: defaults, runners: runners,
                                             availability: backendAvailability, offered: installRunners).setup
        guard let runner = setup.runner else { return [] }
        return BackendSupport.backends(for: runner, translation: setup.translation, availability: backendAvailability)
    }

    // FEX only where the runner serves it, so never on macOS 15; store and installer games run under Rosetta, as Windows installs do.
    func translationChoices(for game: Game) -> [GameSetupChoice.Translation] {
        if game.source.isStore || game.source == .installer { return [.rosetta] }
        return resolution(for: game).setup.runner.map(BackendSupport.translations(for:)) ?? []
    }

    func withVersion(_ game: Game) -> Game {
        guard hasMacBuild(game) else { return game }
        var out = game
        out.version = setup(for: game.id).version ?? .mac
        return out
    }

    // An installer game never goes through Steam: its own launcher is rewritten.
    func tellSteam(_ id: String) {
        guard let game = game(id), game.source != .installer, let appID = game.steamAppID else { return }
        let setup = resolution(for: game).setup
        do {
            let outcome = try GameSetupApplier.apply(setup, appID: appID, tools: backendTools,
                                                     requests: compatRequestsFile, setups: setupsFolder)
            // A Windows choice with no tool would leave Steam on the old mapping while the menu shows the new one.
            if setup.version == .windows, let runner = setup.runner, outcome.tool == nil {
                problem = String(localized: "\(runner.name) \(runner.displayVersion) isn’t available to Steam yet. Steam keeps the previous choice.")
            }
        } catch {
            problem = String(localized: "Cartouche couldn’t pass this setup to Steam: \(error.localizedDescription)")
        }
    }

    // A game mapped in Steam to one of Cartouche's pairs shows that pair here, so the two agree
    func adoptSteamChoices(_ mappings: [Int: String], written: Date? = nil) {
        // A choice Steam has not applied yet, or not saved to config.vdf yet, beats what config.vdf says.
        let pending = SteamCompatChoice.pending(file: compatRequestsFile)
        let asked = SteamCompatChoice.asked(file: compatRequestsFile)
        var updates: [String: GameSetupChoice] = [:]
        for game in allGames {
            guard let appID = game.steamAppID, pending[appID] == nil,
                  written.map({ written in asked[appID].map { $0 < written } ?? true }) ?? (asked[appID] == nil),
                  let name = mappings[appID],
                  let steam = GameSetupApplier.choice(fromTool: name, in: backendTools, runners: runners)
            else { continue }
            var choice = setup(for: game.id)
            guard choice.runnerID != steam.runnerID || choice.graphics != steam.graphics
                || choice.translation != steam.translation || (hasMacBuild(game) && choice.version != .windows)
            else { continue }
            choice.runnerID = steam.runnerID
            choice.graphics = steam.graphics
            choice.translation = steam.translation
            if hasMacBuild(game) { choice.version = .windows }
            updates[game.id] = choice
        }
        adoptSetups(updates)
    }

    // The launcher is rewritten as a store game's would be, DXMT's winemetal.dll refreshed; the game and its prefix are never copied.
    func applyInstallerSetup(_ setup: GameSetupChoice, for game: Game) {
        setupNotices[game.id] = nil
        guard game.id.hasPrefix("installer:") else { return }
        let folder = GameFolder.of(slug: String(game.id.dropFirst("installer:".count)), in: installsFolder)
        guard var record = InstalledGames.record(in: folder) else { return }
        var choice = setup
        choice.translation = .rosetta
        if choice.runnerID == nil { choice.runnerID = game.installRunnerID }
        if choice.graphics == nil { choice.graphics = game.installGraphics }
        let resolved = GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                               availability: backendAvailability, offered: installRunners).setup
        guard let runner = resolved.runner else {
            problem = String(localized: "Set up a runner in Settings > Compatibility to play \(game.name).")
            return
        }
        guard let wine = InstallRunners.wine(for: runner, runners: runnersFolder) else {
            problem = String(localized: "\(runner.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup.")
            return
        }
        // An older Wine than the one that last ran the prefix: warned, still allowed
        if let last = record.wineVersion, record.wineRunnerKind == runner.kind.rawValue,
           last.compare(runner.version, options: .numeric) == .orderedDescending {
            setupNotices[game.id] = String(localized: "This prefix was updated by a newer Wine (\(last)). \(runner.displayVersion) is older and the game may not start.")
        }
        SetupEnvironment.prepare(resolved.backend, prefix: folder.prefix, backends: backendsFolder)
        do {
            try GameLauncher.write(exe: record.exeURL, folder: folder, wine: wine,
                                   backend: resolved.backend, environment: resolved.environment,
                                   backends: backendsFolder, runners: runnersFolder)
            record.runnerID = runner.id
            record.graphics = resolved.backend?.rawValue
            record.wineVersion = runner.version
            record.wineRunnerKind = runner.kind.rawValue
            try InstalledGames.save(record, in: folder)
            showInstalledGames(InstalledGames.all(in: installsFolder))
        } catch {
            problem = String(localized: "Cartouche couldn’t apply this setup: \(error.localizedDescription)")
        }
    }

    // Launchers written before every Wine variable was exported, or for graphics this Mac can no
    // longer load, follow the game's resolved setup. Only on the runner the record names; the files
    // are read and written off the main actor. Run once the runners and their availability are known.
    func refreshInstallerLaunchers() async {
        let installs = installsFolder
        let records = await Task.detached { InstalledGames.all(in: installs) }.value
        let refreshes: [LauncherRefresh] = records.map(Game.init(installed:)).compactMap { game in
            guard let folder = GameFolder.of(game, in: installs) else { return nil }
            let resolved = resolution(for: game).setup
            guard let runner = resolved.runner, runner.id == game.installRunnerID, let backend = resolved.backend,
                  let wine = InstallRunners.wine(for: runner, runners: runnersFolder) else { return nil }
            return LauncherRefresh(folder: folder, wine: wine, backend: backend, environment: resolved.environment,
                                   backends: backendsFolder, runners: runnersFolder)
        }
        guard !refreshes.isEmpty else { return }
        let games = await Task.detached { () -> [InstalledGame]? in
            var changed = false
            for refresh in refreshes {
                if (try? refresh.apply()) == true { changed = true }
            }
            return changed ? InstalledGames.all(in: installs) : nil
        }.value
        if let games { showInstalledGames(games) }
    }

    // Settings > Compatibility's defaults become Steam's tool for every other Windows game
    func tellSteamDefaults() {
        let setup = GameSetupResolver.resolve(GameSetupChoice(), defaults: setupDefaults, runners: runners,
                                              availability: backendAvailability).setup
        guard let pair = GameSetupApplier.tool(for: setup, in: backendTools) else { return }
        do {
            try SteamCompatChoice.request(appID: 0, tool: pair.name, file: compatRequestsFile)
        } catch {
            problem = String(localized: "Cartouche couldn’t pass this setup to Steam: \(error.localizedDescription)")
        }
    }
}

struct LauncherRefresh: Sendable {
    let folder: GameFolder
    let wine: WineRunner
    let backend: GraphicsBackend
    let environment: [String: String]
    let backends: URL
    let runners: URL

    // True when the launcher or the record was rewritten; a launcher that already matches stays as it is.
    func apply() throws -> Bool {
        guard var record = InstalledGames.record(in: folder) else { return false }
        let expected = GameLauncher.script(exe: record.exeURL, prefix: folder.prefix, wine: wine, backend: backend,
                                           environment: environment, backends: backends, runners: runners)
        var changed = false
        if (try? String(contentsOf: folder.launcher, encoding: .utf8)) != expected {
            SetupEnvironment.prepare(backend, prefix: folder.prefix, backends: backends)
            try GameLauncher.write(exe: record.exeURL, folder: folder, wine: wine, backend: backend,
                                   environment: environment, backends: backends, runners: runners)
            changed = true
        }
        if record.graphics != backend.rawValue {
            record.graphics = backend.rawValue
            try InstalledGames.save(record, in: folder)
            changed = true
        }
        return changed
    }
}
