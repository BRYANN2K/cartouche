// The library's view of a game's setup: what the panel and the menus offer, and what
// Steam is told when the user changes it. Requests and per-game variables go to the
// library's own folder, so tests in a scratch folder never reach the real one.

import Foundation

extension LibraryModel {

    var setupDefaults: SetupDefaults { SetupDefaults.load(defaults) }

    var compatRequestsFile: URL { store.folder.appending(path: SupportPaths.compatRequests.lastPathComponent) }
    var setupsFolder: URL { store.folder.appending(path: SupportPaths.setups.lastPathComponent) }

    // A Steam game with both a macOS and a Windows build. An installer game never
    // gets the choice: its folder only holds the Windows install.
    func hasMacBuild(_ game: Game) -> Bool {
        game.source != .installer && game.steamAppID.map(macBuilds.contains) ?? false
    }

    // Runners a Windows installer game may use: the install runners, which allow
    // ready free Wine builds that are not offered to Steam (P6)
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
        // Store games run under Rosetta, as Windows installs do (P10)
        if game.source.isStore { choice.translation = .rosetta }
        return GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                         availability: backendAvailability, hasMacBuild: hasMacBuild(game))
    }

    // What the Graphics menu lists for the game's runner and translation
    func graphicsChoices(for game: Game) -> [GraphicsBackend] {
        let setup = resolution(for: game).setup
        guard let runner = setup.runner else { return [] }
        return BackendSupport.backends(for: runner, translation: setup.translation, availability: backendAvailability)
    }

    // FEX only where the runner serves it, so never on macOS 15; store and
    // installer games run under Rosetta, as Windows installs do
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

    // Asks Steam for the tool of the game's new setup and writes its variables.
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
        // A choice Steam has not applied yet, or not saved to config.vdf yet, is newer than
        // what config.vdf says
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

    // Applies a setup choice to a game installed from a Windows installer: the
    // launcher is rewritten with the same environment a store game would get,
    // DXMT's winemetal.dll is refreshed, and the record keeps the runner that
    // now runs the prefix. The game and its prefix are never copied.
    func applyInstallerSetup(_ setup: GameSetupChoice, for game: Game) {
        setupNotice = nil
        guard game.id.hasPrefix("installer:") else { return }
        let folder = GameFolder(root: installsFolder.appending(path: String(game.id.dropFirst("installer:".count))))
        guard let data = try? Data(contentsOf: folder.record),
              var record = try? InstalledGames.decoder.decode(InstalledGame.self, from: data)
        else { return }
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
            setupNotice = String(localized: "This prefix was updated by a newer Wine (\(last)). \(runner.displayVersion) is older and the game may not start.")
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
