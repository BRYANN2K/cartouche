import Foundation
import RetroArchKit

struct ExtrasSession: Equatable {
    var gameID: String?
    // RetroArch's own answer to GET_OPTION cheevos_hardcore
    var hardcoreReported: Bool?
    var netplay: NetplayRole?
}

struct NetplayRooms: Equatable {
    struct Entry: Equatable, Identifiable {
        let room: NetplayRoom
        let gameID: String
        let gameName: String
        let core: String
        var id: String { room.id }
    }

    var entries: [Entry] = []
    var others = 0
    var localNetwork = false
}

extension ConsoleCenter {

    // MARK: Play Together

    func host(_ id: String, reduceMotion: Bool = false) async {
        _ = await askLocalNetwork()
        await play(id, reduceMotion: reduceMotion, netplay: .host(port: NetplayRole.defaultPort, announce: true))
    }

    func join(_ entry: NetplayRooms.Entry, reduceMotion: Bool = false) async {
        await play(entry.gameID, reduceMotion: reduceMotion, netplay: .join(entry.room.target), core: entry.core)
    }

    func netplayRooms(lobby: NetplayLobby = NetplayLobby(),
                      local: @Sendable () async -> [NetplayRoom] = { await LocalNetplayBrowser.rooms() }) async -> NetplayRooms {
        var found: [NetplayRoom] = []
        var problem: String?
        do {
            found = try await lobby.rooms()
        } catch {
            problem = String(localized: "The lobby did not answer. Games on your network are still listed.")
        }
        let localAllowed = await askLocalNetwork()
        if localAllowed { found = await local() + found }
        var result = NetplayRooms(localNetwork: localAllowed)
        var checksums: [String: UInt32] = [:]
        for room in found {
            var match: NetplayRooms.Entry?
            for game in games where game.exists {
                guard let console = console(of: game), let core = room.core(for: console) else { continue }
                var matches = room.matches(game, console: console)
                if !matches { matches = await crcMatch(room, game, console, &checksums) }
                guard matches else { continue }
                match = NetplayRooms.Entry(room: room, gameID: game.id, gameName: game.name, core: core)
                break
            }
            if let match { result.entries.append(match) } else { result.others += 1 }
        }
        if result.entries.isEmpty, let problem { self.problem = problem }
        return result
    }

    private func crcMatch(_ room: NetplayRoom, _ game: ConsoleGame, _ console: Console, _ cache: inout [String: UInt32]) async -> Bool {
        guard let crc = room.gameCRC, crc != 0, !console.isDisc else { return false }
        if let crc = game.crc { cache[game.id] = crc }
        if cache[game.id] == nil {
            let file = game.fileURL
            cache[game.id] = await Task.detached { (try? CRC32.checksum(of: file)) ?? 0 }.value
        }
        return room.matches(game, console: console, crc: cache[game.id])
    }

    // Local Network, asked once with Cartouche's explanation first. Netplay over the internet works without it.
    func askLocalNetwork() async -> Bool {
        guard let flow = netplayFlow else { return false }
        return await withCheckedContinuation { continuation in
            flow.start(.localNetwork) { outcome in
                continuation.resume(returning: outcome == .allowed || outcome == .pending)
            }
        }
    }

    // MARK: While the game runs

    func startExtras(for game: ConsoleGame, hardcore: Bool, netplay: NetplayRole?) {
        session = ExtrasSession(gameID: game.id, hardcoreReported: nil, netplay: netplay)
        coach = nil
        if extras.coaches(game) { Task { await startCoach(game, hardcore: hardcore) } }
        watchExtras?.cancel()
        guard let runner, extras.login != nil || hardcore else { return }
        // RetroArch logs which game RetroAchievements recognized, and whether hardcore is active, a few seconds after the game starts
        watchExtras = Task { [weak self] in
            var next = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.session.gameID == game.id else { return }
                if let (lines, at) = try? await runner.extrasLog(since: next) {
                    next = at
                    if let id = AchievementsConsole.identifiedGame(in: lines) { self.extras.learn(gameID: id, for: game) }
                }
                if let active = try? await runner.extrasHardcoreActive() { self.session.hardcoreReported = active }
                if self.extras.knownGameID(game) != nil, self.session.hardcoreReported != nil || !hardcore { return }
            }
        }
    }

    func endExtras(_ id: String) async {
        watchExtras?.cancel()
        watchExtras = nil
        await coach?.setTarget(nil)
        coach = nil
        session = ExtrasSession()
        if let game = game(id) { await extras.refresh(game) }
    }

    func translateNow() async {
        guard let runner, playing != nil else { return }
        do {
            try await runner.extrasTranslateNow()
        } catch {
            problem = String(localized: "RetroArch did not translate: \(error.localizedDescription)")
        }
    }

    // MARK: Coach mode

    // The relay reads the game's named values from its Rich Presence script
    func startCoach(_ game: ConsoleGame, hardcore: Bool) async {
        guard let runner else { return }
        var values: [NamedValue] = []
        if let login = extras.login, let id = extras.knownGameID(game),
           let data = try? await extras.client.gameData(id, login: login) {
            values = RichPresence.values(in: data.richPresence)
        }
        let relay = CoachRelay(console: game.console, values: values, target: await runner.extrasCoachTarget(), enabled: true) {
            [weak self] in
            if hardcore { return true }
            return await MainActor.run { self?.session.hardcoreReported ?? false }
        }
        coach = relay
    }
}
