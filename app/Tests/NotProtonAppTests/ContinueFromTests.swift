import CoreGraphics
import Foundation
import ImageIO
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// The RetroArch of the pinned commit and the test core, when the environment
// names them (make retroarch-rig retroarch-testcore), as RetroArchKit's tests use
enum LiveRetroArch {
    static var binary: URL? {
        ProcessInfo.processInfo.environment["CARTOUCHE_RETROARCH"].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    static var core: URL? {
        ProcessInfo.processInfo.environment["CARTOUCHE_TEST_CORE"].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static var available: Bool { binary != nil && core != nil }
    static var video: String { ProcessInfo.processInfo.environment["CARTOUCHE_RETROARCH_VIDEO"] ?? "null" }

    // RetroArch with HOME in the scene's scratch folder and Cartouche's own -c
    @MainActor
    static func player(_ scene: ConsoleScene) async -> ConsolePlayer {
        var launcher = ConsoleLauncher(paths: scene.paths, app: binary!, capabilities: RetroArchCapabilities(mcp: true, version: nil))
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scene.work.appending(path: "home").path(percentEncoded: false)
        // Foundation's home, where RetroArch looks for ~/Documents
        environment["CFFIXED_USER_HOME"] = scene.work.appending(path: "home").path(percentEncoded: false)
        launcher.environment = environment
        let player = ConsolePlayer(launcher: launcher)
        var drivers = ["video_driver": video, "audio_driver": "null", "input_driver": "cocoa", "menu_driver": "rgui",
                       "pause_nonactive": "false", "video_gpu_screenshot": "true"]
        if video == "null" { drivers["savestate_thumbnail_enable"] = "false" }
        await player.setExtra(drivers)
        return player
    }

    // A test cartridge: three colour bytes and a title, for the test core
    static func cartridge() -> Data { Data([0x20, 0x60, 0xC0]) + Data("CARTOUCHE TEST".utf8) }
}

@Suite("Continue From", .serialized)
@MainActor
struct ContinueFromTests {

    @Test("Each picture under Continue From starts the game from its state through the player")
    func slotsGoToThePlayer() async throws {
        let scene = try ConsoleScene("continue")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        try scene.writeState(game, slot: 3, picture: try ConsolePanelTests.screen("SLOT 3"), age: 600)

        await scene.center.play(game.id, slot: 3, reduceMotion: true)
        #expect(await runner.requests.last?.slot == 3)
        #expect(await runner.requests.last?.resume == false)
        #expect(await runner.requests.last?.content == game.fileURL)
        await scene.center.quit()

        // Quit wrote the auto state; Auto now leads Continue From
        let states = await scene.center.states(for: game)
        #expect(states.map(\.title) == ["Auto", "Slot 3"])
        await scene.center.play(game.id, slot: nil, resume: true, reduceMotion: true)
        #expect(await runner.requests.last?.slot == nil)
        #expect(await runner.requests.last?.resume == true)
        await scene.center.quit()
    }

    // The whole path on a real RetroArch: play, save slot 3, quit, then click Slot 3
    @Test("Resume from a state on RetroArch", .enabled(if: LiveRetroArch.available, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE"))
    func resumeOnRetroArch() async throws {
        let scene = try ConsoleScene("continue-live")
        defer { scene.remove() }
        let player = await LiveRetroArch.player(scene)
        scene.center.makeRunner = { _ in player }
        scene.center.resolveCore = { _ in LiveRetroArch.core! }
        let game = try await scene.addGame(console: "snes", name: "Test Cart", data: LiveRetroArch.cartridge(), ext: "ctc")
        #expect(scene.center.game(game.id)?.setup.lowerInputLag == true)

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == nil)
        let session = try #require(await player.session)
        try await Task.sleep(for: .milliseconds(700))
        try await session.setOption("pause", on: true)
        try await session.saveState(slot: 3)
        try await session.setOption("pause", on: false)
        try await Task.sleep(for: .milliseconds(800))
        await scene.center.quit()

        let states = await scene.center.states(for: game)
        #expect(states.map(\.title) == ["Auto", "Slot 3"])
        let pictures = LiveRetroArch.video != "null"
        if pictures { #expect(states.allSatisfy { $0.picture != nil }) }

        // The panel shows them; Slot 3 is clicked
        let texts = try await renderedTexts(
            GamePanel(game: try #require(scene.library.game(game.id)), model: scene.library,
                      compat: try await fixtureCompat(scene.work, defaults: scene.scratch),
                      actions: GameActionRunner(model: scene.library, open: { _ in }))
                .environment(scene.center).environment(\.covers, scene.covers).frame(width: 360, height: 900),
            size: CGSize(width: 360, height: 900), named: "continue-from-live")
        #expect(seen(texts, "Continue From") && seen(texts, "Slot 3") && seen(texts, "Resume"))

        await scene.center.play(game.id, slot: 3, reduceMotion: true)
        let resumed = try #require(await player.session)
        try await resumed.setOption("pause", on: true)
        let status = try await resumed.status()
        #expect(status.content == "Test Cart")
        if pictures, let picture = states.first(where: { $0.slot == 3 })?.picture {
            let a = try #require(try Self.bar(Data(contentsOf: picture)))
            let b = try #require(try Self.bar(await resumed.screenshot()))
            #expect((b - a + 160) % 160 < 30, "slot 3 picture bar \(a), resumed \(b)")
            print("evidence: app Continue From Slot 3 -> RetroArch \(status.state), bar x=\(a) in the slot picture, x=\(b) on screen")
        }
        await scene.center.quit()
    }

    // Darkest to brightest row in the left column, away from the bar: scanlines widen it
    static func rowSpread(_ png: Data) throws -> Int {
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let levels = (height / 3..<(2 * height / 3)).map { y in Int(pixels[(y * width + width / 10) * 4 + 2]) }
        return (levels.max() ?? 0) - (levels.min() ?? 0)
    }

    // Where the white bar of the test core's screen starts, in its 160 columns
    static func bar(_ png: Data) throws -> Int? {
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = height / 2
        return (0..<width).first { x in
            let i = (row * width + x) * 4
            return pixels[i] > 230 && pixels[i + 1] > 230 && pixels[i + 2] > 230
        }.map { $0 * 160 / width }
    }
}
