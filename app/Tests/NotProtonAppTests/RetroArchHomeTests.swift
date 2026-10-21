import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("RetroArch's home and Cartouche quitting", .serialized)
@MainActor
struct RetroArchHomeTests {

    // The app's own path: Settings > Consoles probes the build, the console
    // center makes the player from its launcher. The user's home is stood in
    // for by a scratch folder given as HOME and CFFIXED_USER_HOME.
    @Test("Launched by the app, RetroArch makes nothing in the user's home",
          .enabled(if: LiveRetroArch.available, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE"))
    func nothingInTheUsersHome() async throws {
        let scene = try await ConsoleScene("home")
        defer { scene.remove() }
        let standIn = scene.work.appending(path: "user-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = standIn.path(percentEncoded: false)
        environment["CFFIXED_USER_HOME"] = standIn.path(percentEncoded: false)

        // The default probe, as the app runs it
        let settings = ConsolesSettingsModel(paths: scene.paths, includedApp: LiveRetroArch.binary!, cores: scene.cores,
                                             official: OfficialRelease(paths: scene.paths))
        settings.launchEnvironment = environment
        let center = ConsoleCenter(settings: settings, cores: scene.cores, library: scene.library, database: scene.database)
        center.covers = scene.covers
        center.resolveCore = { _ in LiveRetroArch.core! }
        var drivers = ["video_driver": LiveRetroArch.video, "audio_driver": "null", "input_driver": "cocoa",
                       "menu_driver": "rgui", "pause_nonactive": "false"]
        if LiveRetroArch.video == "null" { drivers["savestate_thumbnail_enable"] = "false" }
        center.playerExtra = drivers

        let file = scene.work.appending(path: "Test Cart.ctc")
        try LiveRetroArch.cartridge().write(to: file)
        await center.add(["snes"])
        try await center.store.add([ConsoleGame(console: "snes", name: "Test Cart", databaseName: nil, file: file, identifiedBy: .chosen)])
        await center.reload()
        let id = try #require(center.games.first?.id)

        await center.play(id, reduceMotion: true)
        #expect(center.problem == nil)
        #expect(center.playing?.phase == .playing)
        try await Task.sleep(for: .milliseconds(600))
        await center.quit()

        let made = (FileManager.default.enumerator(atPath: standIn.path)?.allObjects as? [String]) ?? []
        #expect(made.isEmpty, "RetroArch wrote in the user's home: \(made)")
        #expect(FileManager.default.fileExists(atPath: scene.paths.home.appending(path: "Documents/RetroArch").path(percentEncoded: false)))
        print("evidence: app path (probe, launcher, player): user's home stand-in \(made.isEmpty ? "untouched" : made.joined(separator: ", ")), Documents/RetroArch made under Cartouche's RetroArch home")
    }

    @Test("Cartouche quitting while a game runs: RetroArch quits first and the session's play time is kept")
    func quitWithCartouche() async throws {
        let scene = try await ConsoleScene("terminate")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        await scene.center.play(game.id, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(800))

        scene.center.endForTermination()

        #expect(await runner.quits == 1)
        #expect(scene.center.playing == nil)
        let kept = try #require(await ConsoleLibrary(paths: scene.paths).game(game.id))
        #expect(kept.playSeconds >= 0.8)
        #expect(SaveStates.list(for: kept, in: scene.paths).first?.isAuto == true)
        let asked = ContinuousClock.now
        scene.center.endForTermination()
        #expect(ContinuousClock.now - asked < .milliseconds(100))
    }
}
