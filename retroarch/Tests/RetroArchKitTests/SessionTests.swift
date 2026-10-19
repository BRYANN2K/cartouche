import Foundation
import Testing

@testable import RetroArchKit

// The session manager against fake-retroarch: how it starts RetroArch, what it
// reads from the pipe, and how it stops a build that will not go.
@Suite("RetroArch session", .serialized)
struct SessionTests {

    struct Setup {
        let work: URL
        let paths: RetroArchPaths
        let argsLog: URL

        init() throws {
            work = try scratchFolder("session")
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            argsLog = work.appending(path: "args.jsonl")
        }

        func launch(mcp: Bool = true, _ extra: [String: String] = [:]) -> RetroArchLaunch {
            var launch = RetroArchLaunch(executable: Fixtures.fakeRetroArch, config: AppendConfig(paths: paths), mcp: mcp)
            launch.environment = [
                "FAKE_RA_ARGS": argsLog.path, "FAKE_RA_TOOLS": Fixtures.pinnedToolsList.path,
            ].merging(extra) { $1 }
            return launch
        }

        func launchedWith() throws -> [[String]] {
            try String(contentsOf: argsLog, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode([String].self, from: Data($0.utf8))
            }
        }

        func gone(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
    }

    @Test func startsWithMCPAndItsOwnConfig() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        let tools = await session.tools
        _ = await session.stop()

        #expect(tools.missing.isEmpty)
        let args = try #require(try setup.launchedWith().first)
        #expect(args.first == "--mcp-stdio")
        let config = try #require(args.firstIndex(of: "--appendconfig"))
        #expect(args[config + 1] == setup.paths.appendConfig.path(percentEncoded: false))
        // Cartouche's own retroarch.cfg, never the user's
        let base = try #require(args.firstIndex(of: "-c"))
        #expect(args[base + 1] == setup.paths.baseConfig.path(percentEncoded: false))
        let written = try String(contentsOf: setup.paths.appendConfig, encoding: .utf8)
        #expect(written.contains("config_save_on_exit = \"false\""))
    }

    @Test func loadsAndReportsTheGame() async throws {
        let setup = try Setup()
        let rom = setup.work.appending(path: "Test Cart.sfc")
        try Data([0, 1, 2]).write(to: rom)
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        #expect(try await session.status() == GameStatus(state: .contentless))
        let loaded = try await session.load(core: setup.work.appending(path: "core.dylib"), content: rom)
        #expect(loaded == rom.path(percentEncoded: false))
        #expect(try await session.status() == GameStatus(state: .playing, system: "fake", content: "Test Cart"))
        try await session.saveState(slot: 1)
        try await session.loadState(slot: 1)
        #expect(try await session.screenshot().prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        _ = await session.stop()
    }

    @Test func aRefusedToolIsAnError() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        await #expect(throws: RetroArchSessionError.self) {
            try await session.load(core: nil, content: setup.work.appending(path: "missing.sfc"))
        }
        _ = await session.stop()
    }

    @Test func stopsByClosingThePipe() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        let pid = try #require(await session.processIdentifier)
        let report = await session.stop()
        #expect(report.way == .quit)
        #expect(report.duration < .seconds(3))
        #expect(setup.gone(pid))
        #expect(await session.isRunning == false)
    }

    @Test func aBuildThatIgnoresThePipeIsTerminated() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch(["FAKE_RA_IGNORE_EOF": "1"]))
        try await session.start()
        let pid = try #require(await session.processIdentifier)
        let report = await session.stop()
        #expect(report.way == .terminated)
        #expect(report.duration < .seconds(3))
        #expect(setup.gone(pid))
    }

    @Test func aBuildThatIgnoresSIGTERMIsKilled() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch(["FAKE_RA_IGNORE_EOF": "1", "FAKE_RA_IGNORE_TERM": "1"]))
        try await session.start()
        let pid = try #require(await session.processIdentifier)
        let report = await session.stop()
        #expect(report.way == .killed)
        #expect(report.duration < .seconds(4))
        #expect(setup.gone(pid))
    }

    // A write to a dead RetroArch fails with an error; a SIGPIPE would end
    // the whole test runner, so a passing test is the regression covered
    @Test func writingToAGoneRetroArchFails() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        let pid = try #require(await session.processIdentifier)
        kill(pid, SIGKILL)
        for _ in 0..<50 where !setup.gone(pid) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.gone(pid))
        await #expect(throws: (any Error).self) { try await session.status() }
        _ = await session.stop()
    }

    // A failed load still wrote the token into cartouche.cfg first; play
    // scrubbing it afterwards is what keeps it off disk
    @Test func aFailedLoadScrubsTheToken() async throws {
        let setup = try Setup()
        var launcher = ConsoleLauncher(paths: setup.paths, app: Fixtures.fakeRetroArch,
                                       capabilities: RetroArchCapabilities(mcp: true, version: nil))
        launcher.environment = ["FAKE_RA_TOOLS": Fixtures.pinnedToolsList.path]
        let player = ConsolePlayer(launcher: launcher)
        var request = PlayRequest(core: setup.work.appending(path: "snes9x_libretro.dylib"),
                                  content: setup.work.appending(path: "missing.sfc"))
        request.achievements = AchievementsLogin(username: "tester", token: "SECRET-TOKEN")
        await #expect(throws: (any Error).self) { try await player.play(request) }
        let written = try String(contentsOf: setup.paths.appendConfig, encoding: .utf8)
        #expect(!written.contains("SECRET-TOKEN"))
        #expect(await !player.isPlaying)
    }

    @Test func aBuildThatExitsAtOnceIsReported() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch(["FAKE_RA_EXIT": "3"]))
        await #expect(throws: RetroArchSessionError.exitedEarly(status: 3)) { try await session.start() }
        #expect(await session.isRunning == false)
    }

    @Test func withoutMCPTheGameIsOnTheCommandLine() async throws {
        let setup = try Setup()
        let core = setup.work.appending(path: "snes9x_libretro.dylib")
        let rom = setup.work.appending(path: "Test Cart.sfc")
        let session = RetroArchSession(launch: setup.launch(mcp: false))
        await #expect(throws: RetroArchSessionError.needsMCP) { try await session.start() }
        try await session.start(core: core, content: rom)
        for _ in 0..<100 where (try? setup.launchedWith())?.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        await #expect(throws: RetroArchSessionError.needsMCP) { try await session.status() }
        let report = await session.stop()
        #expect(report.way == .terminated)

        let args = try #require(try setup.launchedWith().first)
        #expect(!args.contains("--mcp-stdio"))
        #expect(Array(args.suffix(3)) == ["-L", core.path(percentEncoded: false), rom.path(percentEncoded: false)])
        #expect(args.contains("--appendconfig"))
    }

    // RetroArch ignores --appendconfig when the -c file is missing
    @Test func cartouchesOwnRetroArchCfgIsMadeOnceAndThenKept() async throws {
        let setup = try Setup()
        let session = RetroArchSession(launch: setup.launch())
        try await session.start()
        _ = await session.stop()
        #expect(FileManager.default.fileExists(atPath: setup.paths.baseConfig.path))
        try Data("video_driver = \"gl\"\n".utf8).write(to: setup.paths.baseConfig)
        try await session.start()
        _ = await session.stop()
        #expect(try String(contentsOf: setup.paths.baseConfig, encoding: .utf8) == "video_driver = \"gl\"\n")
    }

    @Test func anAppIsLaunchedThroughItsBinary() {
        let app = URL(fileURLWithPath: "/Applications/Cartouche.app/Contents/Helpers/RetroArch.app")
        #expect(RetroArchLaunch.binary(app).path == "/Applications/Cartouche.app/Contents/Helpers/RetroArch.app/Contents/MacOS/RetroArch")
    }
}
