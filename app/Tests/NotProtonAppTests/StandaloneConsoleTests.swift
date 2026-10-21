import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Fake standalone emulator apps in the scene's Applications folder: the
// Info.plist the real app carries and a script that writes its arguments, then
// runs until the quit file appears. No real emulator is read, started or changed.
enum FakeEmulatorApp {
    static func install(_ name: String, bundleID: String, version: String, in folder: URL) throws -> URL {
        let app = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        let macos = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": name,
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let script = macos.appending(path: name)
        try """
        #!/bin/sh
        : > "$CARTOUCHE_FAKE_EMULATOR_ARGS"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$CARTOUCHE_FAKE_EMULATOR_ARGS"; done
        trap 'exit 0' TERM
        while [ ! -e "$CARTOUCHE_FAKE_EMULATOR_QUIT" ]; do sleep 0.05; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return app
    }

    static func environment(args: URL, quit: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CARTOUCHE_FAKE_EMULATOR_ARGS"] = args.path(percentEncoded: false)
        environment["CARTOUCHE_FAKE_EMULATOR_QUIT"] = quit.path(percentEncoded: false)
        return environment
    }

    // A GameCube homebrew executable: a DOL header and an endless loop, written here
    static func homebrewDOL() -> Data {
        var dol = Data(count: 0x100)
        func put(_ value: UInt32, at offset: Int) {
            dol.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
        }
        put(0x100, at: 0x00)
        put(0x8000_3100, at: 0x48)
        put(8, at: 0x90)
        put(0x8000_3100, at: 0xE0)
        for word: UInt32 in [0x3860_0000, 0x4800_0000] { dol.append(withUnsafeBytes(of: word.bigEndian) { Data($0) }) }
        return dol
    }
}

@Suite("Standalone emulators in the library", .serialized)
@MainActor
struct StandaloneConsoleTests {

    private func panel(_ scene: ConsoleScene, _ id: String, _ compat: CompatibilityModel) throws -> some View {
        let game = try #require(scene.library.game(id))
        return GamePanel(game: game, model: scene.library, compat: compat,
                         actions: GameActionRunner(model: scene.library, open: { _ in }))
            .environment(scene.center)
            .environment(\.covers, scene.covers)
            .frame(width: 360, height: 980)
    }

    private func sidebar(_ scene: ConsoleScene) -> some View {
        let activity = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                      notifier: RecordingActivityNotifier())
        activity.follow(scene.center)
        return LibrarySidebar(model: scene.library).activitySlot(activity, library: scene.library)
            .environment(scene.center).environment(\.covers, scene.covers)
            .frame(width: 280, height: 560)
    }

    private func dolphinScene(_ label: String) async throws -> (ConsoleScene, ConsoleGame, URL, URL, URL) {
        let scene = try await ConsoleScene(label)
        let app = try FakeEmulatorApp.install("Dolphin", bundleID: "org.dolphin-emu.dolphin", version: "2509", in: scene.applications)
        let args = scene.work.appending(path: "dolphin-args.txt"), quit = scene.work.appending(path: "dolphin-quit")
        scene.center.standaloneEnvironment = FakeEmulatorApp.environment(args: args, quit: quit)
        let game = try await scene.addGame(console: "gamecube", name: "Cartouche Homebrew", data: FakeEmulatorApp.homebrewDOL(), ext: "dol")
        return (scene, game, app, args, quit)
    }

    @Test("GameCube game in Dolphin: batch mode, Playing in the activity slot, quitting Dolphin clears it")
    func gameCubeInDolphin() async throws {
        let (scene, game, _, args, quit) = try await dolphinScene("dolphin-play")
        defer { scene.remove() }
        let gamecube = try #require(ConsoleCatalog.console("gamecube"))
        scene.center.chooseEmulator("dolphin", for: gamecube)
        // RetroArch is never asked
        let retroArch = scene.useFakeRunner(picture: try ConsolePanelTests.screen("NO"))

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == nil)
        #expect(scene.center.playing == Playing(gameID: game.id, phase: .playing, emulator: "Dolphin"))
        #expect(FakeEmulatorApp.arguments(args) == ["-b", "-e", game.fileURL.path])
        #expect(await retroArch.requests.isEmpty)

        let compat = try await fixtureCompat(scene.work, defaults: scene.scratch)
        let slot = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560), named: "p16-activity-dolphin")
        _ = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560), named: "p16-activity-dolphin", dark: true)
        #expect(seen(slot, "Playing on Dolphin") && seen(slot, "Cartouche Homebrew") && seen(slot, "Quit"))
        #expect(!seen(slot, "RetroArch"))
        let panelTexts = try await renderedTexts(try panel(scene, game.id, compat), size: CGSize(width: 360, height: 980), named: "p16-panel-dolphin")
        _ = try await renderedTexts(try panel(scene, game.id, compat), size: CGSize(width: 360, height: 980), named: "p16-panel-dolphin", dark: true)
        #expect(seen(panelTexts, "Playing"))
        #expect(seen(panelTexts, "Plays in Dolphin 2509"))
        #expect(!seen(panelTexts, "Lower input lag"), "RetroArch's setup is not offered for Dolphin")
        print("evidence: Dolphin args \(FakeEmulatorApp.arguments(args)), slot \(slot.filter { $0.contains("Playing") || $0.contains("Homebrew") || $0 == "Quit" }), panel \(panelTexts.prefix(8))")

        // The user quits Dolphin
        try Data().write(to: quit)
        let deadline = Date().addingTimeInterval(5)
        while scene.center.playing != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(scene.center.playing == nil)
        let after = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560), named: "p16-activity-after-quit")
        #expect(!seen(after, "Playing"))
        #expect(try #require(scene.center.game(game.id)).playSeconds > 0)
        #expect(try #require(scene.center.game(game.id)).lastPlayed != nil)
        print("evidence: after Dolphin quit, playing \(String(describing: scene.center.playing)), slot \(after.suffix(3))")
    }

    @Test("Emulator removed: GameCube falls back to RetroArch when its core is here")
    func removedFallsBackToRetroArch() async throws {
        let (scene, game, app, args, _) = try await dolphinScene("dolphin-removed-core")
        defer { scene.remove() }
        let gamecube = try #require(ConsoleCatalog.console("gamecube"))
        scene.center.chooseEmulator("dolphin", for: gamecube)
        #expect(scene.coresFolder.contains("dolphin_libretro.dylib"))
        try FileManager.default.removeItem(at: app)
        let retroArch = scene.useFakeRunner(picture: try ConsolePanelTests.screen("RA"))

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == nil)
        #expect(scene.center.playing == Playing(gameID: game.id, phase: .playing))
        #expect(await retroArch.requests.map(\.core.lastPathComponent) == ["dolphin_libretro.dylib"])
        #expect(!FileManager.default.fileExists(atPath: args.path))
        await scene.center.quit()
    }

    @Test("Emulator removed and no core: Play shows \"Dolphin is not installed\"")
    func removedWithoutCoreSaysNotInstalled() async throws {
        let (scene, game, app, args, _) = try await dolphinScene("dolphin-removed")
        defer { scene.remove() }
        let gamecube = try #require(ConsoleCatalog.console("gamecube"))
        scene.center.chooseEmulator("dolphin", for: gamecube)
        try FileManager.default.removeItem(at: app)
        try FileManager.default.removeItem(at: scene.paths.cores.appending(path: "dolphin_libretro.dylib"))
        let retroArch = scene.useFakeRunner(picture: try ConsolePanelTests.screen("RA"))
        await scene.center.emulators.refresh()

        let compat = try await fixtureCompat(scene.work, defaults: scene.scratch)
        let texts = try await renderedTexts(try panel(scene, game.id, compat), size: CGSize(width: 360, height: 980), named: "p16-panel-not-installed")
        _ = try await renderedTexts(try panel(scene, game.id, compat), size: CGSize(width: 360, height: 980), named: "p16-panel-not-installed", dark: true)
        #expect(seen(texts, "Dolphin is not installed"))
        let system = try #require(scene.center.console(of: game))
        let content = ConsolePanelContent(game: game, console: system, states: [], bios: nil, playing: nil,
                                          route: scene.center.route(for: system))
        #expect(!content.canPlay)
        #expect(content.playNote == "Dolphin is not installed")

        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == "Dolphin is not installed")
        #expect(scene.center.playing == nil)
        #expect(await retroArch.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: args.path))
        print("evidence: Dolphin removed, no core: panel reads \(texts.prefix(6)), problem \(scene.center.problem ?? "")")
    }

    @Test("A console with no RetroArch core and no emulator: Xbox says xemu is not installed")
    func xboxWithoutXemu() async throws {
        let scene = try await ConsoleScene("xbox")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "xbox", name: "Cartouche Homebrew", ext: "iso")
        #expect(scene.coreRequests.isEmpty, "no core is fetched for a console RetroArch cannot play")
        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == "xemu is not installed")
        #expect(scene.center.playing == nil)
    }

    @Test("Cartouche quitting leaves the user's emulator running and keeps the play time")
    func terminationLeavesTheEmulator() async throws {
        let (scene, game, _, _, quit) = try await dolphinScene("dolphin-terminate")
        defer { scene.remove(); try? Data().write(to: quit) }
        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.playing?.emulator == "Dolphin")
        let pid = try #require(await (scene.center.runner as? StandalonePlayer)?.processIdentifier)
        try await Task.sleep(for: .milliseconds(300))
        scene.center.endForTermination()
        #expect(scene.center.playing == nil)
        #expect(kill(pid, 0) == 0, "Dolphin is still running")
        #expect(try #require(await scene.center.store.game(game.id)).playSeconds > 0)
    }
}

extension FakeEmulatorApp {
    static func arguments(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
