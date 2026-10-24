import Foundation
import RetroArchKit

extension StandalonePlayer: ConsoleRunning {
    // The emulator is the user's own app: Cartouche quitting leaves it running
    func leaveForTermination() async -> PlayReport { release() }

    func waitForExit() async {
        if isPlaying { await waitUntilExit() } else { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

extension ConsoleCenter {

    func route(for console: Console) -> ConsoleRoute { emulators.route(for: console) }

    func routeForPlay(_ console: Console) async -> ConsoleRoute {
        await refreshEmulators(for: console)
        return emulators.route(for: console)
    }

    func refreshEmulators(for console: Console) async {
        guard !EmulatorCatalog.emulators(for: console.id).isEmpty else { return }
        await emulators.refresh()
    }

    func chooseEmulator(_ id: String, for console: Console) {
        emulators.choose(id, for: console)
    }

    func playStandalone(_ game: ConsoleGame, in installed: InstalledEmulator, reduceMotion: Bool) async {
        playing = Playing(gameID: game.id, phase: .starting, emulator: installed.emulator.name)
        if !reduceMotion {
            powerOn = PowerOn(gameID: game.id, picture: Self.screenshot(of: game, covers: covers))
        }
        let player = StandalonePlayer(emulator: installed, environment: standaloneEnvironment,
                                      log: paths.logs.appending(path: "\(installed.id).log"))
        runner = player
        do {
            try await player.play(PlayRequest(core: installed.executable, content: game.fileURL))
            playing = Playing(gameID: game.id, phase: .playing, emulator: installed.emulator.name)
            await beginRecord(gameID: game.id, emulator: installed.emulator.name)
            let date = now()
            try? await store.update(game.id) { $0.lastPlayed = date }
            await reload()
            watchForEnd()
        } catch {
            runner = nil
            playing = nil
            powerOn = nil
            problem = String(localized: "\(game.name) could not start in \(installed.emulator.name): \(error.localizedDescription)")
        }
    }
}
