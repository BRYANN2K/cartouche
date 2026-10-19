import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import RetroArchKit

// A real RetroArch of the pinned commit with the test core
// (Tests/testcore/testcore.c) and a test cartridge the test writes itself.
// Run with: make retroarch-rig retroarch-testcore, then CARTOUCHE_RETROARCH
// and CARTOUCHE_TEST_CORE set to what they built.
@Suite(
    "RetroArch integration", .serialized,
    .enabled(if: Rig.hasRetroArchAndCore, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE")
)
struct IntegrationTests {

    struct Game {
        let work: URL
        let paths: RetroArchPaths
        let userConfig: URL
        let rom: URL

        init(_ label: String) throws {
            work = try scratchFolder(label)
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            userConfig = try Rig.userConfig(in: work)
            // A free test cartridge: three colour bytes and a title
            rom = work.appending(path: "Test Cart.ctc")
            try (Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8)).write(to: rom)
        }

        func session(
            _ extra: [String: String] = [:], autoSave: Bool = true,
            baseConfig: RetroArchLaunch.BaseConfig = .cartouche
        ) -> RetroArchSession {
            var config = AppendConfig(paths: paths)
            config.autoSaveState = autoSave
            config.extra = extra
            return RetroArchSession(launch: Rig.launch(config, in: work, baseConfig: baseConfig))
        }

        func stateFile(_ name: String) -> URL? {
            FileManager.default.enumerator(at: paths.states, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func gone(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    @Test func loadAndQueryAGame() async throws {
        let game = try Game("load")
        let session = game.session()

        // From a RetroArch not yet running to the game playing
        let asked = ContinuousClock.now
        try await session.start()
        let loaded = try await session.load(core: Rig.testCore!, content: game.rom)
        let status = try await session.status()
        let took = ContinuousClock.now - asked

        #expect(loaded == game.rom.path(percentEncoded: false))
        #expect(status.state == .playing)
        #expect(status.content == "Test Cart")
        #expect(took < .seconds(5), "playing after \(took)")
        print("evidence: \(status) after \(took)")

        // The frame RetroArch shows: the cartridge's colour, 160 by 144
        try await Task.sleep(for: .milliseconds(300))
        let png = try await session.screenshot()
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })
        #expect(image.width == 160 && image.height == 144)
        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
            try png.write(to: URL(fileURLWithPath: folder).appending(path: "p12-load-and-query.png"))
        }

        try await session.saveState(slot: 1)
        try await session.loadState(slot: 1)
        #expect(game.stateFile("Test Cart.state1") != nil, "STATE save 1 wrote nothing under \(game.paths.states.path)")

        _ = await session.stop()
    }

    @Test func cleanStop() async throws {
        let game = try Game("stop")
        let session = game.session()
        try await session.start()
        try await session.load(core: Rig.testCore!, content: game.rom)
        try await Task.sleep(for: .milliseconds(300))
        let pid = try #require(await session.processIdentifier)

        let report = await session.stop()

        #expect(report.way == .quit, "RetroArch did not quit by itself: \(report.way)")
        #expect(report.duration < .seconds(3), "stopped after \(report.duration)")
        print("evidence: stop \(report.way) after \(report.duration), pid \(pid) gone: \(Self.gone(pid)), auto state: \(game.stateFile("Test Cart.state.auto")?.lastPathComponent ?? "none")")
        #expect(Self.gone(pid), "process \(pid) still exists")
        #expect(game.stateFile("Test Cart.state.auto") != nil, "no auto save state under \(game.paths.states.path)")
    }

    // A build without MCP gets the game on its command line, and answers on
    // the UDP command port instead of the pipe
    @Test func withoutMCPTheGameStartsFromTheCommandLine() async throws {
        let game = try Game("dashl")
        var config = AppendConfig(paths: game.paths)
        config.networkCommands = true
        config.networkCommandPort = UInt16.random(in: 56000...56999)
        var launch = Rig.launch(config, in: game.work)
        launch.mcp = false
        let session = RetroArchSession(launch: launch)
        try await session.start(core: Rig.testCore!, content: game.rom)

        var status: GameStatus?
        for _ in 0..<25 where status?.state != .playing {
            try await Task.sleep(for: .milliseconds(200))
            status = try? await session.status()
        }
        #expect(status?.state == .playing)
        #expect(status?.content == "Test Cart")
        print("evidence: without MCP, UDP GET_STATUS: \(String(describing: status))")

        let report = await session.stop()
        #expect(report.way == .quit)
        #expect(report.duration < .seconds(3))
        #expect(game.stateFile("Test Cart.state.auto") != nil)
    }

    @Test func noAutoSaveStateWhenTurnedOff() async throws {
        let game = try Game("noauto")
        let session = game.session(autoSave: false)
        try await session.start()
        try await session.load(core: Rig.testCore!, content: game.rom)
        #expect(await session.stop().way == .quit)
        #expect(game.stateFile("Test Cart.state.auto") == nil)
    }
}
