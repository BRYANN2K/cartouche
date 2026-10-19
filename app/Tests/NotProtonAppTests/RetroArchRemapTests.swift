import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("Console layouts as RetroArch remap files", .serialized)
struct RetroArchRemapTests {

    static func paths(_ work: URL) -> RetroArchPaths { RetroArchPaths(root: work.appending(path: "retroarch")) }

    static func smw(_ work: URL) -> ConsoleGame {
        ConsoleGame(console: "snes", name: "Super Mario World", databaseName: "Super Mario World (USA)",
                    file: work.appending(path: "games/Super Mario World (USA).sfc"), identifiedBy: .checksum)
    }

    @Test("Presets: Swap A/B trades the two face buttons, Southpaw the sticks; a changed button can go back")
    func presets() {
        let swap = ControllerLayout.preset(.swapAB)
        #expect(swap.target(of: .south) == .east && swap.target(of: .east) == .south)
        #expect(swap.target(of: .west) == .west)
        #expect(swap.preset == .swapAB)
        #expect(ControllerLayout.preset(.southpaw).swapSticks)
        var custom = ControllerLayout()
        custom.set(.north, sends: .west)
        #expect(custom.preset == nil)
        custom.set(.north, sends: .north)
        #expect(custom.isStandard && custom.preset == .standard)
    }

    @Test("Swap A/B as a remap file: player 1's B sends A and A sends B, every other button itself")
    func render() {
        let text = RetroArchRemap.render(.preset(.swapAB))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == RetroArchRemap.header)
        #expect(lines.contains(#"input_libretro_device_p1 = "1""#))
        #expect(lines.contains(#"input_player1_btn_b = "8""#))
        #expect(lines.contains(#"input_player1_btn_a = "0""#))
        #expect(lines.contains(#"input_player1_btn_y = "1""#))
        #expect(lines.contains(#"input_player1_btn_start = "3""#))
        #expect(lines.contains(#"input_player1_btn_r3 = "15""#))
        #expect(lines.filter { $0.hasPrefix("input_player1_btn_") }.count == 16)
    }

    @Test("Swap A/B for a SNES game writes its file under each SNES core's folder; Default removes them")
    func writesAndRemoves() throws {
        let work = try scratchDirectory("remap")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = Self.paths(work)
        let game = Self.smw(work)
        try RetroArchRemap.apply(.preset(.swapAB), game: game, paths: paths)
        let snes9x = paths.menuConfig.appending(path: "remaps/Snes9x/Super Mario World (USA).rmp")
        #expect(RetroArchRemap.file(core: "snes9x", content: game.contentName, paths: paths) == snes9x)
        #expect(try String(contentsOf: snes9x, encoding: .utf8) == RetroArchRemap.render(.preset(.swapAB)))
        for core in ["bsnes", "Mesen-S"] {
            #expect(FileManager.default.fileExists(atPath: paths.menuConfig.appending(path: "remaps/\(core)/Super Mario World (USA).rmp").path))
        }
        print("evidence: \(snes9x.path)")

        try RetroArchRemap.apply(.standard, game: game, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: snes9x.path))
    }

    @Test("A remap file the user saved from RetroArch's own menu is left alone by Default")
    func keepsTheUsersFile() throws {
        let work = try scratchDirectory("remap-user")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = Self.paths(work)
        let game = Self.smw(work)
        let file = RetroArchRemap.file(core: "snes9x", content: game.contentName, paths: paths)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"input_player1_btn_b = "9""#.write(to: file, atomically: true, encoding: .utf8)
        try RetroArchRemap.apply(.standard, game: game, paths: paths)
        #expect(try String(contentsOf: file, encoding: .utf8) == #"input_player1_btn_b = "9""#)
    }

    @Test("A core picked in the game's setup gets the file too")
    func chosenCore() throws {
        let work = try scratchDirectory("remap-core")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = Self.paths(work)
        var game = Self.smw(work)
        game.setup.core = "some_other_core"
        try RetroArchRemap.apply(.preset(.swapAB), game: game, paths: paths)
        #expect(FileManager.default.fileExists(
            atPath: paths.menuConfig.appending(path: "remaps/some_other_core/Super Mario World (USA).rmp").path))
    }

    // The pinned RetroArch with the test core: cartouche.cfg sends RetroArch to the
    // remaps folder, and the game's file is what it loads with the game
    @Test("RetroArch loads the game's remap file when the game starts",
          .enabled(if: LiveRetroArch.available, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE"))
    func retroArchLoadsIt() async throws {
        let work = try scratchDirectory("remap-live")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = Self.paths(work)
        let rom = work.appending(path: "Test Cart.ctc")
        try LiveRetroArch.cartridge().write(to: rom)
        // RetroArch names the folder after the core's library_name
        try RetroArchRemap.apply(.preset(.swapAB), core: "Cartouche Test Core", content: "Test Cart", paths: paths)
        let file = RetroArchRemap.file(core: "Cartouche Test Core", content: "Test Cart", paths: paths)

        var launcher = ConsoleLauncher(paths: paths, app: LiveRetroArch.binary!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
        launcher.environment = ConsoleLauncher.environment(ProcessInfo.processInfo.environment, home: work.appending(path: "home"))
        var launch = launcher.launch()
        launch.verbose = true
        launch.config.extra = ["video_driver": LiveRetroArch.video, "audio_driver": "null", "input_driver": "cocoa",
                               "menu_driver": "rgui", "pause_nonactive": "false", "savestate_thumbnail_enable": "false"]
        let session = RetroArchSession(launch: launch)
        try await session.start()
        try await session.load(core: LiveRetroArch.core!, content: rom)
        try await Task.sleep(for: .milliseconds(500))
        _ = await session.stop()

        let log = try String(contentsOf: await session.stderrLog, encoding: .utf8)
        let lines = log.split(separator: "\n").filter { $0.contains("[Remap]") }
        print("evidence: " + lines.joined(separator: "\nevidence: "))
        #expect(lines.contains { $0.contains("Game-specific remap found") && $0.contains(file.path(percentEncoded: false)) })
    }
}
