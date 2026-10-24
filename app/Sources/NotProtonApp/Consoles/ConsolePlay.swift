import Foundation
import RetroArchKit

protocol ConsoleRunning: Sendable {
    func play(_ request: PlayRequest) async throws
    func setLook(_ look: ConsoleLook) async throws
    func setLowerInputLag(_ on: Bool) async throws
    func setHardcore(_ on: Bool) async throws
    func setDisc(_ disc: Int) async throws
    func quit() async -> PlayReport
    func ended() async -> PlayReport?
    func waitForExit() async
    func leaveForTermination() async -> PlayReport
    var processIdentifier: Int32? { get async }
}

extension ConsoleRunning {
    func leaveForTermination() async -> PlayReport { await quit() }
    func waitForExit() async { try? await Task.sleep(for: .seconds(1)) }
    var processIdentifier: Int32? { nil }
}

extension ConsolePlayer: ConsoleRunning {
    var processIdentifier: Int32? {
        get async { await session?.processIdentifier }
    }

    func waitForExit() async {
        if let session {
            await session.waitUntilExit()
        } else {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

protocol ConsoleExtrasRunning {
    func log(since: Int) async throws -> (lines: [String], next: Int)
    func hardcoreActive() async throws -> Bool
    func translateNow() async throws
    func coachTarget() async -> (any CoachTarget)?
}

extension ConsoleRunning {
    func extrasLog(since: Int) async throws -> (lines: [String], next: Int) {
        guard let player = self as? any ConsoleExtrasRunning else { throw RetroArchSessionError.needsMCP }
        return try await player.log(since: since)
    }

    func extrasHardcoreActive() async throws -> Bool {
        guard let player = self as? any ConsoleExtrasRunning else { throw RetroArchSessionError.needsMCP }
        return try await player.hardcoreActive()
    }

    func extrasTranslateNow() async throws {
        guard let player = self as? any ConsoleExtrasRunning else { throw RetroArchSessionError.needsMCP }
        try await player.translateNow()
    }

    func extrasCoachTarget() async -> (any CoachTarget)? {
        await (self as? any ConsoleExtrasRunning)?.coachTarget()
    }
}

extension ConsolePlayer: ConsoleExtrasRunning {
    func coachTarget() async -> (any CoachTarget)? { session }
}

struct Playing: Equatable {
    enum Phase: Equatable { case starting, playing }

    let gameID: String
    var phase: Phase
    // The standalone emulator it plays in; nil for RetroArch
    var emulator: String?
}

struct PowerOn: Equatable {
    let gameID: String
    let picture: URL?
}

extension ConsoleCenter {

    // MARK: What the panel shows

    func console(of game: ConsoleGame) -> Console? { ConsoleCatalog.console(game.console) }

    func states(for game: ConsoleGame) async -> [SaveState] {
        if let cached = statesCache[game.id], cached.stamp == statesChanged { return cached.states }
        let stamp = statesChanged
        let paths = paths
        let states = await Task.detached { SaveStates.list(for: game, in: paths) }.value
        statesCache[game.id] = (stamp, states)
        return states
    }

    func bios(for game: ConsoleGame) async -> BIOSStatus? {
        guard let console = console(of: game) else { return nil }
        let paths = paths
        let stamp = await Task.detached { Self.biosStamp(in: paths.bios) }.value
        if let cached = biosCache[game.id], cached.stamp == stamp { return cached.status }
        let status = await Task.detached { BIOSChecker(paths: paths).status(for: console) }.value
        biosCache[game.id] = (stamp, status)
        return status
    }

    nonisolated static func biosStamp(in folder: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.sorted().map { name -> String in
            let values = try? folder.appending(path: name)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(name)=\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ",")
    }

    func isPlaying(_ id: String) -> Bool { playing?.gameID == id }

    // MARK: Setup

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

    func play(_ id: String, slot: Int? = nil, resume: Bool = false, reduceMotion: Bool = false,
              netplay: NetplayRole? = nil, core: String? = nil) async {
        guard let game = game(id), let console = console(of: game), playing == nil else { return }
        problem = nil
        playing = Playing(gameID: id, phase: .starting)
        let route = await routeForPlay(console)
        if let missing = route.missingText {
            playing = nil
            problem = missing
            return
        }
        if let installed = route.emulator {
            await playStandalone(game, in: installed, reduceMotion: reduceMotion)
            return
        }
        if let bios = await bios(for: game), !bios.isReady {
            playing = nil
            problem = bios.message
            return
        }
        if !reduceMotion {
            powerOn = PowerOn(gameID: id, picture: Self.screenshot(of: game, covers: covers))
        }
        do {
            // A joined game plays with the host's core
            let core = core ?? game.setup.core ?? console.core
            let coreURL: URL
            if let resolveCore {
                coreURL = try await resolveCore(core)
            } else {
                try await cores.install(core)
                coreURL = try await cores.ready(core)
            }
            if settings.capabilities == nil { await settings.refresh() }
            runner = makeRunner(settings)
            if !playerExtra.isEmpty, let player = runner as? ConsolePlayer { await player.setExtra(playerExtra) }
            guard let runner else { throw RetroArchSessionError.notRunning }
            var request = PlayRequest(core: coreURL, content: game.fileURL)
            // Hardcore forbids states: the game starts from the beginning
            request.slot = game.setup.hardcore ? nil : slot
            request.resume = game.setup.hardcore ? false : resume
            request.look = game.setup.look
            request.lowerInputLag = game.setup.lowerInputLag
            request.hardcore = game.setup.hardcore
            request.disc = game.isMultiDisc ? min(game.setup.disc, game.discs.count - 1) : 0
            request.netplay = netplay
            extras.apply(to: &request, game: game)
            if extras.cloudSaves {
                let cloud = extras.cloud
                try await Task.detached { try cloud.ensure() }.value
            }
            try await runner.play(request)
            playing = Playing(gameID: id, phase: .playing)
            await beginRecord(gameID: id, emulator: nil)
            startExtras(for: game, hardcore: request.hardcore, netplay: netplay)
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

    func quit() async {
        guard let runner, playing != nil else { return }
        watchPlay?.cancel()
        let report = await runner.quit()
        await finish(report)
    }

    // RetroArch quits first, writing its auto state; off the main thread, as the app is in its last turn there.
    func endForTermination(limit: TimeInterval = 4) {
        guard let id = playing?.gameID, let runner else { return }
        watchPlay?.cancel()
        let store = store, date = now()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let report = await runner.leaveForTermination()
            try? await store.update(id) { game in
                game.playSeconds += report.played.seconds
                game.lastPlayed = date
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + limit) == .success {
            endRecord()
        } else {
            heartbeat?.cancel()
            heartbeat = nil
            sessions.heartbeat()
        }
        playing = nil
        powerOn = nil
    }

    func finish(_ report: PlayReport) async {
        guard let id = playing?.gameID else { return }
        let seconds = report.played.seconds
        let date = now()
        try? await store.update(id) { game in
            game.playSeconds += seconds
            game.lastPlayed = date
        }
        endRecord()
        if playing?.emulator != nil || runner is OrphanedRunner { runner = nil }
        playing = nil
        powerOn = nil
        statesChanged += 1
        await reload()
        await endExtras(id)
    }

    // MARK: The session record

    // A heartbeat each minute lets a killed Cartouche pick the session back up; without the process start there is nothing to check a pid against.
    func beginRecord(gameID: String, emulator: String?) async {
        guard let runner, let pid = await runner.processIdentifier,
              let start = sessions.processStart(pid) else { return }
        let date = now()
        sessions.write(ConsoleSessionRecord(gameID: gameID, emulator: emulator, pid: pid,
                                            processStarted: start, started: date, heartbeat: date))
        startHeartbeat()
    }

    func startHeartbeat() {
        heartbeat?.cancel()
        let sessions = sessions, every = heartbeatEvery
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                sessions.heartbeat()
            }
        }
    }

    func endRecord() {
        heartbeat?.cancel()
        heartbeat = nil
        sessions.clear()
    }

    // A leftover record means Cartouche was killed mid-game: same pid AND same start is picked up, gone is counted to the last heartbeat; the current pid holder is never signaled.
    func reattachOrphaned() async {
        guard playing == nil else { return }
        // A killed Cartouche may have left the RetroAchievements token on disk
        ConsolePlayer.scrubSecrets(in: paths)
        sessions.clearUnreadable()
        guard let record = sessions.read() else { return }
        if sessions.isSameProcess(record) {
            runner = OrphanedRunner(record: record, sessions: sessions)
            playing = Playing(gameID: record.gameID, phase: .playing, emulator: record.emulator)
            startHeartbeat()
            watchForEnd()
            await reload()
            AppLog.note("console session picked up: \(record.gameID) pid \(record.pid)")
        } else {
            let seconds = max(0, record.heartbeat.timeIntervalSince(record.started))
            try? await store.update(record.gameID) {
                $0.playSeconds += seconds
                $0.lastPlayed = record.heartbeat
            }
            endRecord()
            await reload()
            AppLog.note("console session counted after Cartouche was killed: \(record.gameID) \(Int(seconds))s")
        }
    }

    func watchForEnd() {
        watchPlay?.cancel()
        watchPlay = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let runner = self.runner, self.playing != nil else { return }
                await runner.waitForExit()
                guard !Task.isCancelled, self.playing != nil else { return }
                if let report = await runner.ended() {
                    await self.finish(report)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // The game's screenshot from libretro-thumbnails, when it was fetched
    static func screenshot(of game: ConsoleGame, covers: CoverStore) -> URL? {
        guard case .image(let url) = covers.local(for: libraryGame(game), kind: .hero, override: nil) else { return nil }
        return url
    }
}

private extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
