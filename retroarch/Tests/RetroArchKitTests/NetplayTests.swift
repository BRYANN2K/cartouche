import Foundation
import Testing

@testable import RetroArchKit

// Play Together: the lobby's rooms, the local network's, and how RetroArch is
// started to host or join one
@Suite("Netplay")
struct NetplayTests {

    static let lobby = """
    [{"fields": {"id": 1, "username": "player42", "country": "fr", "game_name": "Cartouche Homebrew (World)",
      "game_crc": "1A2B3C4D", "core_name": "Snes9x", "core_version": "1.63 4c8ab51", "subsystem_name": "N/A",
      "retroarch_version": "1.22.2", "frontend": "darwin ARMv8", "ip": "203.0.113.7", "port": 55435,
      "mitm_ip": "198.51.100.20", "mitm_port": 55436, "mitm_session": "abcdef0123456789", "host_method": 3,
      "has_password": false, "has_spectate_password": false, "connectable": true, "is_retroarch": true,
      "player_count": 1, "spectator_count": 0, "created": "2026-10-19T07:45:51Z", "updated": "2026-10-19T07:46:51Z"}},
     {"fields": {"id": 2, "username": "friend", "game_name": "Quest", "game_crc": "00000000", "core_name": "SameBoy",
      "core_version": "v1.0", "ip": "203.0.113.9", "port": 55500, "mitm_ip": "", "mitm_port": 0, "mitm_session": "",
      "host_method": 2, "has_password": true}},
     {"fields": {"username": "broken"}}]
    """

    @Test func lobbyRoomsJoinThroughTheRelayOrDirectly() {
        let rooms = NetplayLobby.rooms(from: Data(Self.lobby.utf8))
        #expect(rooms.count == 2)
        let relayed = rooms[0]
        #expect(relayed.nickname == "player42" && relayed.gameName == "Cartouche Homebrew (World)")
        #expect(relayed.gameCRC == 0x1A2B_3C4D && relayed.coreName == "Snes9x" && relayed.origin == .lobby)
        #expect(relayed.target == NetplayTarget(address: "198.51.100.20", port: 55436, session: "abcdef0123456789"))
        let direct = rooms[1]
        #expect(direct.target == NetplayTarget(address: "203.0.113.9", port: 55500))
        #expect(direct.hasPassword)
    }

    @Test func theLobbyIsAskedForItsList() async throws {
        let asked = AskedURLs()
        let lobby = NetplayLobby(base: URL(string: "http://lobby.test/")!) { url in
            asked.add(url)
            return (Data(Self.lobby.utf8), 200)
        }
        #expect(try await lobby.rooms().count == 2)
        #expect(asked.urls == [URL(string: "http://lobby.test/list")!])
        let down = NetplayLobby(base: URL(string: "http://lobby.test/")!) { _ in (Data(), 503) }
        await #expect(throws: NetplayLobby.Problem.unavailable(status: 503)) { try await down.rooms() }
        #expect(NetplayLobby.libretro.absoluteString == "http://lobby.libretro.com/")
    }

    @Test func aLocalRoomReadsRetroArchsBonjourRecord() throws {
        // RetroArch writes %08x of htonl(crc)
        let txt = ["content_crc": "4d3c2b1a", "nick": "player42", "core": "Snes9x", "core_version": "1.63",
                   "content": "Cartouche Homebrew", "has_password": "false"]
        let room = try #require(LocalNetplay.room(txt: txt, address: "192.168.1.20", port: 55435))
        #expect(room.gameCRC == 0x1A2B_3C4D)
        #expect(room.target == NetplayTarget(address: "192.168.1.20", port: 55435))
        #expect(room.origin == .localNetwork && !room.hasPassword)
        #expect(LocalNetplay.serviceType == "_ra_netplay._tcp")
    }

    @Test func aRoomIsTheGameOfTheLibraryWithTheSameFileAndACoreOfItsConsole() throws {
        let snes = try #require(ConsoleCatalog.console("snes"))
        let gb = try #require(ConsoleCatalog.console("gb"))
        let game = ConsoleGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)",
                               file: URL(fileURLWithPath: "/games/Cartouche Homebrew (World).sfc"), identifiedBy: .checksum)
        var room = NetplayLobby.rooms(from: Data(Self.lobby.utf8))[0]
        #expect(room.core(for: snes) == "snes9x")
        #expect(room.matches(game, console: snes, crc: 0x1A2B_3C4D))
        #expect(!room.matches(game, console: snes, crc: 0x0BAD_F00D))
        // No checksum to compare: the file's name
        #expect(room.matches(game, console: snes))
        #expect(!room.matches(game, console: gb))
        room.coreName = "Some Other Core"
        #expect(!room.matches(game, console: snes, crc: 0x1A2B_3C4D))
    }

    @Test func hostAndJoinAreRetroArchsOwnFlags() {
        var launch = RetroArchLaunch(executable: URL(fileURLWithPath: "/RA.app"),
                                     config: AppendConfig(paths: RetroArchPaths(root: URL(fileURLWithPath: "/tmp/ra"))))
        launch.netplay = .host(port: 55435, announce: true)
        #expect(launch.arguments().suffix(3) == ["--host", "--port", "55435"])
        launch.netplay = .join(NetplayTarget(address: "198.51.100.20", port: 55436, session: "abcdef"))
        #expect(launch.arguments().suffix(6) == ["--connect", "198.51.100.20", "--port", "55436", "--mitm-session", "abcdef"])
        launch.netplay = .join(NetplayTarget(address: "192.168.1.20", port: 55435))
        #expect(!launch.arguments().contains("--mitm-session"))
        launch.netplay = nil
        #expect(!launch.arguments().contains("--host") && !launch.arguments().contains("--connect"))
    }

    @Test func aHostedGameIsAnnouncedThroughTheRelayWithTheNickname() {
        var config = AppendConfig(paths: RetroArchPaths(root: URL(fileURLWithPath: "/tmp/ra")))
        func value(_ key: String) -> String? { config.values.first { $0.0 == key }?.1 }
        #expect(value("netplay_public_announce") == "false")
        #expect(value("netplay_use_mitm_server") == "false")
        #expect(value("network_cmd_bind_address") == "127.0.0.1")
        config.netplayAnnounce = true
        config.netplayNickname = "player42"
        #expect(value("netplay_public_announce") == "true")
        #expect(value("netplay_use_mitm_server") == "true")
        #expect(value("netplay_nickname") == "player42")
    }
}

final class AskedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.withLock { list.append(url) } }
    var urls: [URL] { lock.withLock { list } }
}

// Two RetroArch of the pinned commit on this Mac: one hosts, the other joins
// it on 127.0.0.1, as a friend on the same network would on its address
@Suite(
    "Netplay on RetroArch", .serialized,
    .enabled(if: Rig.hasRetroArchAndCore, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE")
)
struct NetplayIntegrationTests {

    static func player(_ label: String, in work: URL) async -> (ConsolePlayer, RetroArchPaths) {
        let paths = RetroArchPaths(root: work.appending(path: label))
        let model = Rig.launch(AppendConfig(paths: paths), in: work.appending(path: "\(label)-scratch"))
        var launcher = ConsoleLauncher(paths: paths, app: Rig.retroarch!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
        launcher.environment = model.environment
        let player = ConsolePlayer(launcher: launcher)
        // The log says who joined as which player; nothing pauses while unfocused
        await player.setExtra(model.config.extra.merging(["log_verbosity": "true", "pause_nonactive": "false"]) { $1 })
        return (player, paths)
    }

    static func waitFor(_ text: String, in player: ConsolePlayer, within limit: Duration) async throws -> String? {
        let end = ContinuousClock.now + limit
        var next = 0
        while ContinuousClock.now < end {
            let (lines, at) = try await player.log(since: next)
            next = at
            if let line = lines.first(where: { $0.contains(text) }) { return line }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func hostAndJoinWithinTenSeconds() async throws {
        let work = try scratchFolder("netplay")
        defer { try? FileManager.default.removeItem(at: work) }
        let rom = work.appending(path: "Test Cart.ctc")
        try (Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8)).write(to: rom)
        let port = UInt16.random(in: 56000...56900)

        let (host, _) = await Self.player("host", in: work)
        var hosting = PlayRequest(core: Rig.testCore!, content: rom)
        hosting.netplay = .host(port: port, announce: false)
        hosting.netplayNickname = "player-a"
        try await host.play(hosting)

        // B opens Join and picks A's room: from here, at most ten seconds
        let clicked = ContinuousClock.now
        let (guest, _) = await Self.player("guest", in: work)
        var joining = PlayRequest(core: Rig.testCore!, content: rom)
        joining.netplay = .join(NetplayTarget(address: "127.0.0.1", port: port))
        joining.netplayNickname = "player-b"
        try await guest.play(joining)

        let joined = try await Self.waitFor("You have joined as player 2", in: guest, within: .seconds(10))
        let seen = try await Self.waitFor("player-b has joined as player 2", in: host, within: .seconds(10) - (ContinuousClock.now - clicked))
        let took = ContinuousClock.now - clicked
        #expect(joined != nil, "the guest never became player 2")
        #expect(seen != nil, "the host never saw player 2 join")
        #expect(took < .seconds(10), "took \(took)")
        print("evidence: host on 127.0.0.1:\(port); guest: \(joined ?? "-"); host: \(seen ?? "-"); \(took) from Join")

        await guest.quit()
        await host.quit()
    }
}
