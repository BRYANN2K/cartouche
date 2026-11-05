import Foundation

extension LibraryModel {

    // An updated runner takes over from the old build: installer games' launchers and records, setups and the default.
    // Prefixes stay. When a step fails, every file and setting written so far is put back and the error is thrown.
    func moveGames(from old: String, to new: Runner) async throws {
        let installs = installsFolder, runnersFolder = self.runnersFolder, backends = backendsFolder
        let records = await Task.detached { InstalledGames.all(in: installs) }.value
        // Each game's new launcher is written from its scan: the walks end before the jobs resolve
        await scanGames(records.filter { $0.runnerID == old }.map(Game.init(installed:)))
        let jobs = records.filter { $0.runnerID == old }.compactMap { record -> (Game, RunnerMigration.Job)? in
            job(for: record, to: new, installs: installs).map { (Game(installed: record), $0) }
        }
        let rollback = try await Task.detached {
            try RunnerMigration.move(jobs.map(\.1), to: new, runners: runnersFolder, backends: backends)
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
        for (game, job) in jobs { noteLaunch(of: game, environment: job.environment) }
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
        let profile = launchProfile(for: game)
        let resolved = GameSetupResolver.resolve(choice, defaults: setupDefaults, runners: runners,
                                                 availability: backendAvailability, offered: installRunners,
                                                 profile: profile).setup
        // A setup the new build cannot resolve keeps the game's own graphics and variables, never the library's
        guard resolved.runner?.id == new.id else {
            return RunnerMigration.Job(folder: folder, backend: record.backend,
                                       environment: LaunchProfile.filteredEnvironment(
                                           (choice.environment ?? [:]).filter { !OverlayLaunch.variables.contains($0.key) },
                                           dlss: profile.dlss))
        }
        return RunnerMigration.Job(folder: folder, backend: resolved.backend, environment: resolved.environment)
    }
}
