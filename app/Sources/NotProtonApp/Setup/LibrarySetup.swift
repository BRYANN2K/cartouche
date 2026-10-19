// The library's view of a game's setup: what the panel and the menus offer, and what
// Steam is told when the user changes it. Requests and per-game variables go to the
// library's own folder, so tests in a scratch folder never reach the real one.

import Foundation

extension LibraryModel {

    var setupDefaults: SetupDefaults { SetupDefaults.load(defaults) }

    var compatRequestsFile: URL { store.folder.appending(path: SupportPaths.compatRequests.lastPathComponent) }
    var setupsFolder: URL { store.folder.appending(path: SupportPaths.setups.lastPathComponent) }

    // A Steam game with both a macOS and a Windows build
    func hasMacBuild(_ game: Game) -> Bool {
        game.steamAppID.map(macBuilds.contains) ?? false
    }

    func resolution(for game: Game) -> GameSetupResolver.Resolution {
        var choice = setup(for: game.id)
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

    // FEX only where the runner serves it, so never on macOS 15
    func translationChoices(for game: Game) -> [GameSetupChoice.Translation] {
        if game.source.isStore { return [.rosetta] }
        return resolution(for: game).setup.runner.map(BackendSupport.translations(for:)) ?? []
    }

    func withVersion(_ game: Game) -> Game {
        guard hasMacBuild(game) else { return game }
        var out = game
        out.version = setup(for: game.id).version ?? .mac
        return out
    }

    // Asks Steam for the tool of the game's new setup and writes its variables
    func tellSteam(_ id: String) {
        guard let game = game(id), let appID = game.steamAppID else { return }
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
