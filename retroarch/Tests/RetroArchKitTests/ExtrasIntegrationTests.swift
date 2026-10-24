import CryptoKit
import Foundation
import Testing

@testable import RetroArchKit

// Achievements, hardcore, iCloud Drive and the coach on a RetroArch of the
// pinned commit, built with achievements (make retroarch-rig), signed in to a
// RetroAchievements stand-in on 127.0.0.1
@Suite(
    "Console extras on RetroArch", .serialized,
    .enabled(if: Rig.hasRetroArchAndCore, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE")
)
struct ExtrasIntegrationTests {

    struct Scene {
        let work: URL
        let paths: RetroArchPaths
        let rom: URL
        let player: ConsolePlayer

        init(_ label: String, root: String = "cartouche") async throws {
            work = try scratchFolder("extras-\(label)")
            paths = RetroArchPaths(root: work.appending(path: root))
            // The test cartridge, named as a Game Boy file so rcheevos hashes it
            rom = work.appending(path: "Test Cart.gb")
            try (Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8)).write(to: rom)
            let model = Rig.launch(AppendConfig(paths: paths), in: work)
            var launcher = ConsoleLauncher(paths: paths, app: Rig.retroarch!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
            launcher.environment = model.environment
            player = ConsolePlayer(launcher: launcher)
            await player.setExtra(model.config.extra)
        }

        var request: PlayRequest { PlayRequest(core: Rig.testCore!, content: rom) }
    }

    static func rigHasAchievements(_ player: ConsolePlayer) async -> Bool {
        (try? await player.session?.option("cheevos_enable")) != nil
    }

    static func until(_ limit: Duration, _ check: () async throws -> Bool) async rethrows -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if try await check() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    @Test func hardcoreIsActiveAndForbidsStatesAndRewind() async throws {
        let scene = try await Scene("hardcore")
        defer { try? FileManager.default.removeItem(at: scene.work) }
        let server = try AchievementsServer()
        let host = try await server.start()
        defer { server.stop() }

        var request = scene.request
        request.hardcore = true
        request.achievements = AchievementsLogin(username: "tester", token: server.token, host: host)
        try await scene.player.play(request)
        guard await Self.rigHasAchievements(scene.player) else {
            await scene.player.quit()
            Issue.record("the rig was built without achievements: make retroarch-rig again")
            return
        }
        // The token was read: cartouche.cfg no longer holds it
        let appended = try String(contentsOf: scene.paths.appendConfig, encoding: .utf8)
        #expect(!appended.contains(server.token))

        // rcheevos signs in and recognizes the game over HTTP, a moment after the load
        var lines: [String] = []
        var next = 0
        _ = try await Self.until(.seconds(10)) {
            let (logged, at) = try await scene.player.log(since: next)
            lines += logged
            next = at
            return AchievementsConsole.identifiedGame(in: lines) != nil
        }
        try await Task.sleep(for: .milliseconds(500))
        let active = try await scene.player.hardcoreActive()
        let session = try #require(await scene.player.session)
        if let (logged, _) = try? await scene.player.log(since: next) { lines += logged }
        #expect(active, "RetroArch never reported hardcore; log: \(lines.suffix(20))")
        #expect(AchievementsConsole.identifiedGame(in: lines) == 4242, "\(lines.suffix(20))")
        #expect(try await session.option("rewind") == "off")
        // RetroArch still saves a state in hardcore, but loads none: Continue From cannot work
        try await session.saveState(slot: 1)
        var refusal = ""
        do {
            try await session.loadState(slot: 1)
        } catch RetroArchSessionError.toolFailed(_, let reason) {
            refusal = reason
        }
        #expect(!refusal.isEmpty, "slot 1 loaded in hardcore")
        // Signed in with the token, never a password
        let sent = server.requests
        #expect(sent.contains { $0.r == "login2" && $0.fields["t"] == server.token })
        #expect(!sent.contains { $0.fields["p"] != nil })
        print("evidence: GET_OPTION cheevos_hardcore=on (\(active)), rewind=off, STATE load refused: \(refusal.trimmingCharacters(in: .whitespacesAndNewlines)); rcheevos: \(lines.filter { $0.contains("RCHEEVOS") && ($0.contains("hardcore") || $0.contains("Identified")) }); requests \(sent.map(\.r))")

        if AchievementsConsole.identifiedGame(in: lines) == nil, let log = try? String(contentsOf: scene.paths.logs.appending(path: "retroarch.log"), encoding: .utf8) {
            print("diagnostic: " + lines.suffix(40).joined(separator: "\ndiagnostic: ") + "\nstderr: " + log.suffix(3000))
        }
        await scene.player.quit()
        // Nothing of the token is left in Cartouche's RetroArch folder
        let files = FileManager.default.enumerator(atPath: scene.paths.root.path)?.allObjects as? [String] ?? []
        for file in files {
            let url = scene.paths.root.appending(path: file)
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { continue }
            #expect(data.range(of: Data(server.token.utf8)) == nil, "\(file) holds the token")
        }
    }

    @Test func theCoachReadsInHardcoreAndIsRefusedInput() async throws {
        let scene = try await Scene("coach")
        defer { try? FileManager.default.removeItem(at: scene.work) }
        var request = scene.request
        request.hardcore = true
        try await scene.player.play(request)
        try await Task.sleep(for: .milliseconds(500))
        let session = try #require(await scene.player.session)
        // The test core keeps its frame count in its RAM, from 0
        let values = RichPresence.values(in: "Display:\nFrame @Frames(0xX0000)")
        let relay = CoachRelay(console: "test", values: values, target: session, enabled: true) { true }
        let first = try await relay.read("Frames").value
        try await Task.sleep(for: .milliseconds(300))
        let second = try await relay.read("Frames").value
        #expect(second > first && first > 0, "frames \(first) then \(second)")
        let pressed = await relay.call("coach_press", ["player": 1, "control": "a", "frames": 3])
        let text = pressed["content"]?.array?.first?["text"]?.string ?? ""
        #expect(pressed["isError"] == .bool(true) && text.contains("Hardcore mode"))
        // Outside hardcore the same press reaches RetroArch
        let open = CoachRelay(console: "test", values: values, target: session, enabled: true) { false }
        let reply = try await open.press(player: 1, control: "a", frames: 2)
        print("evidence: Frames read through the relay \(first) then \(second); press in hardcore -> \(text); outside hardcore RetroArch answered \(reply)")
        await scene.player.quit()
    }

    @Test func aStateSavedOnMacAIsContinuedOnMacB() async throws {
        let a = try await Scene("cloud-a", root: "mac-a")
        defer { try? FileManager.default.removeItem(at: a.work) }
        let drive = a.work.appending(path: "iCloud Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let macB = RetroArchPaths(root: a.work.appending(path: "mac-b"))
        try await CloudSaves(paths: a.paths, drive: drive).turnOn()
        try await CloudSaves(paths: macB, drive: drive).turnOn()

        try await a.player.play(a.request)
        try await Task.sleep(for: .milliseconds(500))
        let session = try #require(await a.player.session)
        try await session.saveState(slot: 2)
        await a.player.quit()

        let onB = SaveStates.list(contentName: "Test Cart", in: macB.states)
        #expect(onB.contains { $0.slot == 2 }, "\(onB.map(\.title))")
        #expect(onB.contains { $0.isAuto })
        print("evidence: Mac B lists \(onB.map(\.title)) from \(onB.first?.file.deletingLastPathComponent().path ?? "-")")
    }
}
