// Playing a console game: Play, Resume or a Continue From slot starts it in
// RetroArch with the panel's setup; Quit ends it with an auto state and adds
// the session to the game's play time.

import Foundation
import RetroArchKit

// What plays the games: RetroArchKit's ConsolePlayer, or a stand-in in tests
protocol ConsoleRunning: Sendable {
    func play(_ request: PlayRequest) async throws
    func setLook(_ look: ConsoleLook) async throws
    func setLowerInputLag(_ on: Bool) async throws
    func setHardcore(_ on: Bool) async throws
    func setDisc(_ disc: Int) async throws
    func quit() async -> PlayReport
    // RetroArch quit by itself: what was played
    func ended() async -> PlayReport?
}

extension ConsolePlayer: ConsoleRunning {}

struct Playing: Equatable {
    enum Phase: Equatable { case starting, playing }

    let gameID: String
    var phase: Phase
}

// The CRT power-on over the window: the game's screenshot, if Cartouche has one
struct PowerOn: Equatable {
    let gameID: String
    let picture: URL?
}

extension ConsoleCenter {

    // MARK: What the panel shows

    func console(of game: ConsoleGame) -> Console? { ConsoleCatalog.console(game.console) }

    func states(for game: ConsoleGame) -> [SaveState] {
        _ = statesChanged
        return SaveStates.list(for: game, in: paths)
    }

    func bios(for game: ConsoleGame) -> BIOSStatus? {
        console(of: game).map { BIOSChecker(paths: paths).status(for: $0) }
    }

    func isPlaying(_ id: String) -> Bool { playing?.gameID == id }

    // MARK: Setup

    // Kept for the game; applied at once when it is the one playing
    func setSetup(_ id: String, _ change: @escaping @Sendable (inout ConsoleGameSetup) -> Void) async {
        guard let before = game(id)?.setup else { return }
        do {
            try await store.update(id) { change(&$0.setup) }
        } catch {
            problem = error.localizedDescription
        }
        await reload()
        guard isPlaying(id), let runner, let after = game(id)?.setup else { return }
        do {
            if after.look != before.look { try await runner.setLook(after.look) }
            if after.lowerInputLag != before.lowerInputLag { try await runner.setLowerInputLag(after.lowerInputLag) }
            if after.hardcore != before.hardcore { try await runner.setHardcore(after.hardcore) }
            if after.disc != before.disc { try await runner.setDisc(after.disc) }
        } catch {
            problem = String(localized: "RetroArch did not take the change: \(error.localizedDescription)")
        }
    }

    // MARK: Play and quit

    // Play, Resume (the auto state) or one slot under Continue From
    func play(_ id: String, slot: Int? = nil, resume: Bool = false, reduceMotion: Bool = false) async {
        guard let game = game(id), let console = console(of: game), playing == nil else { return }
        problem = nil
        if let bios = bios(for: game), !bios.isReady {
            problem = bios.message
            return
        }
        playing = Playing(gameID: id, phase: .starting)
        if !reduceMotion {
            powerOn = PowerOn(gameID: id, picture: Self.screenshot(of: game, covers: covers))
        }
        do {
            let core = game.setup.core ?? console.core
            let coreURL: URL
            if let resolveCore {
                coreURL = try await resolveCore(core)
            } else {
                // A core picked in Setup is downloaded the first time it plays
                try await cores.install(core)
                coreURL = try await cores.ready(core)
            }
            if runner == nil {
                if settings.capabilities == nil { await settings.refresh() }
                runner = makeRunner(settings)
                if !playerExtra.isEmpty, let player = runner as? ConsolePlayer { await player.setExtra(playerExtra) }
            }
            guard let runner else { throw RetroArchSessionError.notRunning }
            var request = PlayRequest(core: coreURL, content: game.fileURL)
            request.slot = slot
            request.resume = resume
            request.look = game.setup.look
            request.lowerInputLag = game.setup.lowerInputLag
            request.hardcore = game.setup.hardcore
            request.disc = game.isMultiDisc ? min(game.setup.disc, game.discs.count - 1) : 0
            try await runner.play(request)
            playing = Playing(gameID: id, phase: .playing)
            let date = now()
            try? await store.update(id) { $0.lastPlayed = date }
            await reload()
            watchForEnd()
        } catch {
            playing = nil
            powerOn = nil
            problem = String(localized: "\(game.name) could not start: \(error.localizedDescription)")
        }
    }

    // Quit in the activity slot: RetroArch writes its auto state and goes
    func quit() async {
        guard let runner, playing != nil else { return }
        watchPlay?.cancel()
        let report = await runner.quit()
        await finish(report)
    }

    // Cartouche is quitting: RetroArch quits first, writing its auto state, and
    // the session's play time is kept. The work runs off the main thread, as
    // the app is in its last turn there; it waits at most the limit.
    func endForTermination(limit: TimeInterval = 4) {
        guard let id = playing?.gameID, let runner else { return }
        watchPlay?.cancel()
        let store = store, date = now()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let report = await runner.quit()
            let seconds = Double(report.played.components.seconds) + Double(report.played.components.attoseconds) / 1e18
            try? await store.update(id) { game in
                game.playSeconds += seconds
                game.lastPlayed = date
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + limit)
        playing = nil
        powerOn = nil
    }

    private func finish(_ report: PlayReport) async {
        guard let id = playing?.gameID else { return }
        let seconds = Double(report.played.components.seconds) + Double(report.played.components.attoseconds) / 1e18
        let date = now()
        try? await store.update(id) { game in
            game.playSeconds += seconds
            game.lastPlayed = date
        }
        playing = nil
        powerOn = nil
        statesChanged += 1
        await reload()
    }

    // A RetroArch closed from its own menu or window ends the session too
    private func watchForEnd() {
        watchPlay?.cancel()
        watchPlay = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let runner = self.runner, self.playing != nil else { return }
                if let report = await runner.ended() {
                    await self.finish(report)
                    return
                }
            }
        }
    }

    // The game's screenshot from libretro-thumbnails, when it was fetched
    static func screenshot(of game: ConsoleGame, covers: CoverStore) -> URL? {
        guard case .image(let url) = covers.local(for: libraryGame(game), kind: .hero, override: nil) else { return nil }
        return url
    }
}
