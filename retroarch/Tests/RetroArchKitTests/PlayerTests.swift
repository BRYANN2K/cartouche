import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import RetroArchKit

@Suite("Console player")
struct PlayerTests {

    @Test func savedStatesAreListedWithTheirPictures() throws {
        let work = try scratchFolder("states")
        let folder = work.appending(path: "states/Cartouche Test Core", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, age) in [("Game.state3", 300.0), ("Game.state1", 600.0), ("Game.state.auto", 30.0), ("Game.state", 900.0),
                            ("Other.state2", 10.0), ("Game.srm", 5.0)] {
            let file = folder.appending(path: name)
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        try Data([2]).write(to: folder.appending(path: "Game.state3.png"))
        try Data([2]).write(to: folder.appending(path: "Game.state.auto.png"))
        let states = SaveStates.list(contentName: "Game", in: work.appending(path: "states"))
        #expect(states.map(\.title) == ["Auto", "Slot 3", "Slot 1", "Slot 0"])
        #expect(states.map { $0.picture != nil } == [true, true, false, false])
    }

    @Test func looksAreWrittenForBothShaderLanguages() throws {
        let paths = RetroArchPaths(root: try scratchFolder("looks"))
        try Looks.install(in: paths)
        for look in [ConsoleLook.crt, .lcd] {
            for language in Looks.Language.allCases {
                let preset = try #require(Looks.preset(look, language, in: paths))
                let text = try String(contentsOf: preset, encoding: .utf8)
                #expect(text.contains("shader0 = \(look.rawValue).\(language.rawValue)"))
                #expect(FileManager.default.fileExists(atPath: paths.shaders.appending(path: "\(look.rawValue).\(language.rawValue)").path))
            }
        }
        #expect(Looks.preset(.original, .slang, in: paths) == nil)
        let crt = try String(contentsOf: paths.shaders.appending(path: "crt.slang"), encoding: .utf8)
        #expect(crt.contains("#pragma stage fragment") && crt.contains("scan"))
    }

    @Test func retroArchsHomeIsCartouchesWhateverTheUsersIs() {
        let paths = RetroArchPaths(root: URL(fileURLWithPath: "/tmp/cartouche-ra"))
        var launcher = ConsoleLauncher(paths: paths, app: URL(fileURLWithPath: "/tmp/RetroArch.app"),
                                       capabilities: RetroArchCapabilities(mcp: true, version: nil))
        launcher.environment = ["HOME": "/Users/someone", "CFFIXED_USER_HOME": "/Users/someone", "PATH": "/usr/bin"]
        let environment = launcher.launch().environment ?? [:]
        #expect(environment["HOME"] == "/tmp/cartouche-ra/home/")
        #expect(environment["CFFIXED_USER_HOME"] == "/tmp/cartouche-ra/home/")
        #expect(environment["PATH"] == "/usr/bin")
        // Without one given, the app's own environment, with the same home
        launcher.environment = nil
        #expect(launcher.launch().environment?["CFFIXED_USER_HOME"] == "/tmp/cartouche-ra/home/")
    }

    @Test func thePanelsChoicesGoIntoTheAppendedConfig() {
        var config = AppendConfig(paths: RetroArchPaths(root: URL(fileURLWithPath: "/tmp/cartouche-ra")))
        func value(_ key: String) -> String? { config.values.first { $0.0 == key }?.1 }
        #expect(value("savestate_auto_load") == "false")
        #expect(value("run_ahead_enabled") == "false")
        #expect(value("video_shader_dir") == "/tmp/cartouche-ra/shaders/")
        config.autoLoadState = true
        config.runAhead = true
        config.hardcore = true
        #expect(value("savestate_auto_load") == "true")
        #expect(value("run_ahead_enabled") == "true")
        #expect(value("run_ahead_frames") == "1")
        #expect(value("run_ahead_secondary_instance") == "false")
        #expect(value("cheevos_hardcore_mode_enable") == "true")
    }
}

// The player on a real RetroArch of the pinned commit with the test core.
// make retroarch-rig retroarch-testcore, then CARTOUCHE_RETROARCH and
// CARTOUCHE_TEST_CORE; CARTOUCHE_RETROARCH_VIDEO=gl for pictures and shaders.
@Suite(
    "Console player on RetroArch", .serialized,
    .enabled(if: Rig.hasRetroArchAndCore, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE")
)
struct PlayerIntegrationTests {

    struct Scene {
        let work: URL
        let paths: RetroArchPaths
        let rom: URL
        let player: ConsolePlayer

        init(_ label: String) async throws {
            work = try scratchFolder("player-\(label)")
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            rom = work.appending(path: "Test Cart.ctc")
            try (Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8)).write(to: rom)
            // As Rig.launch: drivers for the test machine, HOME in the scratch folder
            let model = Rig.launch(AppendConfig(paths: paths), in: work)
            var launcher = ConsoleLauncher(paths: paths, app: Rig.retroarch!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
            launcher.environment = model.environment
            player = ConsolePlayer(launcher: launcher)
            await player.setExtra(model.config.extra)
        }

        var request: PlayRequest { PlayRequest(core: Rig.testCore!, content: rom) }

        var states: [SaveState] { SaveStates.list(contentName: "Test Cart", in: paths.states) }
    }

    static var pictures: Bool { Rig.video != "null" }

    // Where the white bar starts on a picture of the test core's screen
    static func bar(_ png: Data) throws -> Int? {
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = height / 2
        let x = (0..<width).first { x in
            let i = (row * width + x) * 4
            return pixels[i] > 230 && pixels[i + 1] > 230 && pixels[i + 2] > 230
        }
        return x.map { $0 * 160 / width }
    }

    @Test func resumeFromSlotThreeShowsThatMoment() async throws {
        let scene = try await Scene("slot")
        try await scene.player.play(scene.request)
        let session = try #require(await scene.player.session)
        try await Task.sleep(for: .milliseconds(700))
        // Held still, so the state and the frame shown are the same moment
        try await session.setOption("pause", on: true)
        try await session.saveState(slot: 3)
        let savedBar = try Self.bar(await session.screenshot())
        try await session.setOption("pause", on: false)
        try await Task.sleep(for: .milliseconds(900))
        let report = await scene.player.quit()
        #expect(report.stop.way == .quit)

        let states = scene.states
        #expect(states.map(\.title) == ["Auto", "Slot 3"])
        let slot3 = try #require(states.first { $0.slot == 3 })
        if Self.pictures { #expect(slot3.picture != nil, "no picture beside \(slot3.file.lastPathComponent)") }

        // Clicking Slot 3 under Continue From
        var request = scene.request
        request.slot = 3
        try await scene.player.play(request)
        let resumed = try #require(await scene.player.session)
        try await resumed.setOption("pause", on: true)
        let status = try await resumed.status()
        let screen = try await resumed.screenshot()
        let screenBar = try Self.bar(screen)
        #expect(status.state == .paused || status.state == .playing)
        // The bar moves a pixel a frame; a few frames run between the load and the pause
        let a = try #require(savedBar), b = try #require(screenBar)
        let moved = (b - a + 160) % 160
        #expect(moved < 30, "slot 3 showed the bar at x=\(a), the resumed game at x=\(b)")
        var line = "evidence: slot 3 saved with the bar at x=\(a); resumed from slot 3 with the bar at x=\(b), status \(status.state)"
        if let picture = slot3.picture {
            let pictureBar = try Self.bar(Data(contentsOf: picture))
            line += "; the slot's own picture has it at x=\(pictureBar.map(String.init) ?? "-")"
            if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
                let out = URL(fileURLWithPath: folder)
                try? FileManager.default.removeItem(at: out.appending(path: "p13-slot3-picture.png"))
                try FileManager.default.copyItem(at: picture, to: out.appending(path: "p13-slot3-picture.png"))
                try screen.write(to: out.appending(path: "p13-slot3-resumed.png"))
            }
        }
        print(line)
        await scene.player.quit()
    }

    // The user's home stood in for by a scratch folder: RetroArch is started as
    // the app starts it, from an environment whose HOME and CFFIXED_USER_HOME are
    // that folder, and must leave it alone
    @Test func theUsersHomeIsNeverRetroArchsHome() async throws {
        let work = try scratchFolder("player-home")
        let standIn = work.appending(path: "user-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let rom = work.appending(path: "Test Cart.ctc")
        try (Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8)).write(to: rom)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = standIn.path
        environment["CFFIXED_USER_HOME"] = standIn.path
        var launcher = ConsoleLauncher(paths: paths, app: Rig.retroarch!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
        launcher.environment = environment
        let player = ConsolePlayer(launcher: launcher)
        await player.setExtra(Rig.launch(AppendConfig(paths: paths), in: work).config.extra)
        try await player.play(PlayRequest(core: Rig.testCore!, content: rom))
        try await Task.sleep(for: .milliseconds(500))
        await player.quit()

        let made = (FileManager.default.enumerator(atPath: standIn.path)?.allObjects as? [String]) ?? []
        #expect(made.isEmpty, "RetroArch wrote in the user's home: \(made)")
        // What it makes under ~ is in Cartouche's folder instead
        let home = (FileManager.default.enumerator(atPath: paths.home.path)?.allObjects as? [String]) ?? []
        #expect(home.contains("Documents/RetroArch/playlists/builtin"), "\(home)")
        print("evidence: user's home stand-in after a launch and quit: \(made.isEmpty ? "empty" : made.joined(separator: ", ")); Cartouche's RetroArch home holds \(home.filter { $0.split(separator: "/").count <= 3 })")
    }

    @Test func lookAppliesWithinASecond() async throws {
        let scene = try await Scene("look")
        // Screenshots of what the window shows, shader included
        await scene.player.setExtra(await scene.player.extra.merging(["video_gpu_screenshot": "true"]) { $1 })
        try await scene.player.play(scene.request)
        try await Task.sleep(for: .milliseconds(400))
        let session = try #require(await scene.player.session)
        guard Self.pictures else {
            // No video driver, no shader to run
            await #expect(throws: RetroArchSessionError.self) { try await scene.player.setLook(.crt) }
            await scene.player.quit()
            return
        }
        try await session.setOption("pause", on: true)
        let before = try await session.screenshot()
        let asked = ContinuousClock.now
        try await scene.player.setLook(.crt)
        let took = ContinuousClock.now - asked
        let after = try await session.screenshot()
        #expect(took < .seconds(1), "applied after \(took)")
        // Scanlines: rows of the plain blue picture now differ in brightness
        let spread = try Self.rowSpread(after), plain = try Self.rowSpread(before)
        #expect(spread > plain + 20, "row brightness spread \(plain) before, \(spread) after")
        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
            try before.write(to: URL(fileURLWithPath: folder).appending(path: "p13-look-original.png"))
            try after.write(to: URL(fileURLWithPath: folder).appending(path: "p13-look-crt.png"))
        }
        print("evidence: CRT applied in \(took); row brightness spread \(plain) -> \(spread)")
        try await scene.player.setLook(.original)
        await scene.player.quit()
    }

    // Darkest to brightest row in the left column, away from the bar
    static func rowSpread(_ png: Data) throws -> Int {
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = width / 10
        let levels = (height / 3..<(2 * height / 3)).map { y in Int(pixels[(y * width + x) * 4 + 2]) }
        return (levels.max() ?? 0) - (levels.min() ?? 0)
    }

    @Test func quitWritesTheAutoStateAndReportsTheTimePlayed() async throws {
        let scene = try await Scene("quit")
        let start = Date()
        try await scene.player.play(scene.request)
        try await Task.sleep(for: .seconds(1.5))
        let report = await scene.player.quit()
        #expect(report.stop.way == .quit)
        #expect(report.played >= .seconds(1.5) && report.played < .seconds(4), "played \(report.played)")
        let auto = try #require(scene.states.first { $0.isAuto })
        #expect(auto.date >= start.addingTimeInterval(-1))
        if Self.pictures { #expect(auto.picture != nil) }
        #expect(await !scene.player.isPlaying)
        print("evidence: Quit -> \(report.stop.way) in \(report.stop.duration), played \(report.played), auto state \(auto.file.lastPathComponent) picture \(auto.picture?.lastPathComponent ?? "none")")

        // Resume loads it: the game goes on from where Quit left it
        var request = scene.request
        request.resume = true
        try await scene.player.play(request)
        let session = try #require(await scene.player.session)
        try await session.setOption("pause", on: true)
        if let picture = auto.picture, let a = try Self.bar(Data(contentsOf: picture)), let b = try Self.bar(await session.screenshot()) {
            #expect((b - a + 160) % 160 < 30, "auto picture bar x=\(a), resumed x=\(b)")
        }
        await scene.player.quit()
    }
}
