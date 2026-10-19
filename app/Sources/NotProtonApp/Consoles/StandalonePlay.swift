// Console games that play in a standalone emulator the user installed (P16):
// Dolphin, PCSX2, PPSSPP, Azahar, xemu or Ryubing. The emulator starts the
// game with its documented arguments and its own settings; the activity slot
// shows it until the emulator quits.

import Foundation
import RetroArchKit

extension StandalonePlayer: ConsoleRunning {
    // The emulator is the user's own app: Cartouche quitting leaves it running
    func leaveForTermination() async -> PlayReport { release() }
}

extension ConsoleCenter {

    // Where the console's games play, from what was last found
    func route(for console: Console) -> ConsoleRoute { emulators.route(for: console) }

    // The folders are read again at Play, so an emulator removed since is noticed
    func routeForPlay(_ console: Console) async -> ConsoleRoute {
        await refreshEmulators(for: console)
        return emulators.route(for: console)
    }

    // Only consoles a standalone emulator plays need the folders read
    func refreshEmulators(for console: Console) async {
        guard !EmulatorCatalog.emulators(for: console.id).isEmpty else { return }
        await emulators.refresh()
    }

    func chooseEmulator(_ id: String, for console: Console) {
        emulators.choose(id, for: console)
    }

    // playing is already .starting when this runs
    func playStandalone(_ game: ConsoleGame, in installed: InstalledEmulator, reduceMotion: Bool) async {
        playing = Playing(gameID: game.id, phase: .starting, emulator: installed.emulator.name)
        if !reduceMotion {
            powerOn = PowerOn(gameID: game.id, picture: Self.screenshot(of: game, covers: covers))
        }
        let player = StandalonePlayer(emulator: installed, environment: standaloneEnvironment,
                                      log: paths.logs.appending(path: "\(installed.id).log"))
        runner = player
        do {
            // The emulator reads the game file; core is not used
            try await player.play(PlayRequest(core: installed.executable, content: game.fileURL))
            playing = Playing(gameID: game.id, phase: .playing, emulator: installed.emulator.name)
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
