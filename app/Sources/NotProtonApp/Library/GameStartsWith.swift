//// Starts With: the program an installer game starts with, changed from the menus or the panel. The folder scans and
//// the rewrite run detached; the menus only read the last answer.

import Foundation
import InstallerKit

extension LibraryModel {

    // A game already scanned is skipped unless asked again, as the panel does for the game it shows.
    func refreshExeOptions(for games: [Game], force: Bool = false) {
        let folders = games.compactMap { game -> (String, GameFolder)? in
            guard force || exeOptions[game.id] == nil, game.installed else { return nil }
            return GameFolder.of(game, in: installsFolder).map { (game.id, $0) }
        }
        guard !folders.isEmpty else { return }
        Task { [weak self] in
            let found = await Task.detached { () -> [String: GameExecutable.Options] in
                var out: [String: GameExecutable.Options] = [:]
                for (id, folder) in folders {
                    if let record = InstalledGames.record(in: folder) { out[id] = GameExecutable.options(for: record) }
                }
                return out
            }.value
            self?.exeOptions.merge(found) { _, new in new }
        }
    }

    func exeChoices(for game: Game) -> [GameExecutable.Choice] {
        GameExecutable.listed(exeOptions[game.id], current: game.executable)
    }

    // The folder the picker opens in and is limited to.
    func exeFolder(for game: Game) -> URL? {
        exeOptions[game.id]?.folder ?? game.executable?.deletingLastPathComponent()
    }

    // Never while the game runs, installs or is already changing; busy answers come from the cached probe.
    func canChangeExe(_ game: Game, installs: InstallCenter = .shared) -> Bool {
        game.source == .installer && game.installed && !changingExe.contains(game.id) && !installs.isBusy(game)
    }

    // The launcher is rewritten for the game's current setup and the record keeps its prefix and settings; the
    // runtimes the new program needs and the prefix lacks are installed after.
    func changeExe(of game: Game, to exe: URL, installs: InstallCenter = .shared) async {
        guard canChangeExe(game, installs: installs), let folder = GameFolder.of(game, in: installsFolder) else { return }
        let setup = resolution(for: game).setup
        guard let runner = setup.runner else {
            problem = String(localized: "Set up a runner in Settings > Compatibility to play \(game.name).")
            return
        }
        guard let wine = InstallRunners.wine(for: runner, runners: runnersFolder) else {
            problem = String(localized: "\(runner.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup.")
            return
        }
        changingExe.insert(game.id)
        defer { changingExe.remove(game.id) }
        let backends = backendsFolder, winetricks = exeWinetricks, installsFolder = installsFolder
        do {
            let (change, all) = try await Task.detached { () throws -> (GameExecutable.Change, [InstalledGame]) in
                let change = try GameExecutable.change(to: exe, folder: folder, wine: wine, backend: setup.backend,
                                                       environment: setup.environment, backends: backends)
                return (change, InstalledGames.all(in: installsFolder))
            }.value
            showInstalledGames(all)
            guard !change.runtimes.isEmpty else { return }
            let steps = change.runtimes
            let log = folder.root.appending(path: PrefixTools.winetricksLogName)
            try await Task.detached {
                let installed = await GameExecutable.install(steps, prefix: folder.prefix, wine: wine, log: log,
                                                             winetricks: winetricks)
                guard !installed.isEmpty, var record = InstalledGames.record(in: folder) else { return }
                let added = installed.filter { !record.redistributables.contains($0) }
                record.redistributables += added
                try InstalledGames.save(record, in: folder)
            }.value
        } catch {
            problem = String(localized: "Cartouche couldn’t change the program \(game.name) starts with: \(error.localizedDescription)")
        }
    }
}
