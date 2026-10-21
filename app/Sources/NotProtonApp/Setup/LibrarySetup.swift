
import Foundation

extension LibraryModel {

    var setupDefaults: SetupDefaults { SetupDefaults.load(defaults) }

    var compatRequestsFile: URL { store.folder.appending(path: SupportPaths.compatRequests.lastPathComponent) }
    var setupsFolder: URL { store.folder.appending(path: SupportPaths.setups.lastPathComponent) }

    // An installer game never gets the choice: its folder only holds the Windows install.
    func hasMacBuild(_ game: Game) -> Bool {
        game.source != .installer && game.steamAppID.map(macBuilds.contains) ?? false
    }

    // Install runners allow ready free Wine builds that Steam games are not offered.
    var installRunners: [Runner] { InstallRunners.choices(RunnerRegistry(runners: runners)) }

    func resolution(for game: Game) -> GameSetupResolver.Resolution {
        var choice = setup(for: game.id)
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
                                         availability: backendAvailability, hasMacBuild: hasMacBuild(game))
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
        do {
            try GameSetupApplier.apply(resolution(for: game).setup, appID: appID, tools: backendTools,
                                       requests: compatRequestsFile, setups: setupsFolder)
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
        let folder = GameFolder(root: installsFolder.appending(path: String(game.id.dropFirst("installer:".count))))
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
            problem = String(localized: "\(runner.kind.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup.")
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
                                   backends: backendsFolder)
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
