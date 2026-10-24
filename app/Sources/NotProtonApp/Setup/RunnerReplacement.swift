import Foundation

extension LibraryModel {

    // An updated runner takes over from the old build: installer games' launchers and records, setups and the default.
    // Prefixes stay. When a step fails, every file and setting written so far is put back and the error is thrown.
    func moveGames(from old: String, to new: Runner) async throws {
        let installs = installsFolder, runnersFolder = self.runnersFolder, backends = backendsFolder
        let records = await Task.detached { InstalledGames.all(in: installs) }.value
        let jobs = records.filter { $0.runnerID == old }.compactMap { job(for: $0, to: new, installs: installs) }
        let rollback = try await Task.detached {
            try RunnerMigration.move(jobs, to: new, runners: runnersFolder, backends: backends)
        }.value
        let moved: [String]
        do {
            moved = try replaceRunnerInSetups(old, with: new.id)
        } catch {
            await Task.detached { rollback.restore() }.value
            throw error
        }
        let defaultMoved = RunnerMigration.replacing(old, with: new.id, in: setupDefaults)
        defaultMoved?.save(defaults)
        if !jobs.isEmpty {
            let games = await Task.detached { InstalledGames.all(in: installs) }.value
            showInstalledGames(games)
        }
        // Steam's own choice follows, now that the new build's tools are listed
        await reloadRunners?()
        for id in moved where game(id)?.source != .installer { tellSteam(id) }
        if defaultMoved != nil { tellSteamDefaults() }
    }

    private func job(for record: InstalledGame, to new: Runner, installs: URL) -> RunnerMigration.Job? {
        let game = Game(installed: record)
        guard let folder = GameFolder.of(game, in: installs) else { return nil }
        var choice = setup(for: game.id)
        choice.translation = .rosetta
        choice.runnerID = new.id
        if choice.graphics == nil { choice.graphics = game.installGraphics }
        let resolved = GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                                 availability: backendAvailability, offered: installRunners).setup
        // A setup the new build cannot resolve keeps the game's own graphics and variables
        guard resolved.runner?.id == new.id else {
            return RunnerMigration.Job(folder: folder, backend: record.backend, environment: choice.environment ?? [:])
        }
        return RunnerMigration.Job(folder: folder, backend: resolved.backend, environment: resolved.environment)
    }
}
