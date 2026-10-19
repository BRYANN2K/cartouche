import Foundation
import Testing

@testable import RetroArchKit

// P16: where each console's games play, the choice kept per console, and
// starting a game in a fake emulator app made in a scratch folder
@Suite("Standalone emulator launch", .serialized)
struct StandaloneLaunchTests {

    private func dolphin(_ version: String = "2509") -> InstalledEmulator {
        InstalledEmulator(emulator: EmulatorCatalog.emulator("dolphin")!, app: URL(fileURLWithPath: "/Applications/Dolphin.app"),
                          executable: URL(fileURLWithPath: "/Applications/Dolphin.app/Contents/MacOS/Dolphin"), version: version)
    }

    @Test func aDetectedEmulatorPlaysItsConsolesByDefault() {
        let gamecube = ConsoleCatalog.console("gamecube")!
        #expect(ConsoleRoute.resolve(gamecube, choice: nil, installed: [dolphin()], coreReady: true) == .standalone(dolphin()))
        #expect(ConsoleRoute.resolve(ConsoleCatalog.console("wii")!, choice: nil, installed: [dolphin()], coreReady: true)
                == .standalone(dolphin()))
        // No emulator found: RetroArch, as P13 plays it
        #expect(ConsoleRoute.resolve(gamecube, choice: nil, installed: [], coreReady: false) == .retroArch)
        // SNES has no standalone emulator here
        #expect(ConsoleRoute.resolve(ConsoleCatalog.console("snes")!, choice: "dolphin", installed: [dolphin()], coreReady: true)
                == .retroArch)
    }

    @Test func retroArchCanBeChosenWhenTheConsoleHasACore() {
        let psp = ConsoleCatalog.console("psp")!
        let ppsspp = InstalledEmulator(emulator: EmulatorCatalog.emulator("ppsspp")!, app: URL(fileURLWithPath: "/A/PPSSPPSDL.app"),
                                       executable: URL(fileURLWithPath: "/A/PPSSPPSDL.app/Contents/MacOS/PPSSPPSDL"), version: "1.20.4")
        #expect(psp.hasCore)
        #expect(ConsoleRoute.resolve(psp, choice: EmulatorChoice.retroArch, installed: [ppsspp], coreReady: false) == .retroArch)
        #expect(ConsoleRoute.resolve(psp, choice: "ppsspp", installed: [ppsspp], coreReady: true) == .standalone(ppsspp))
    }

    // Emulator removed: RetroArch if a core exists, otherwise "Dolphin is not installed"
    @Test func aRemovedEmulatorFallsBackOrSaysItIsNotInstalled() {
        let gamecube = ConsoleCatalog.console("gamecube")!
        #expect(ConsoleRoute.resolve(gamecube, choice: "dolphin", installed: [], coreReady: true) == .retroArch)
        let route = ConsoleRoute.resolve(gamecube, choice: "dolphin", installed: [], coreReady: false)
        #expect(route == .missing(EmulatorCatalog.emulator("dolphin")!))
        #expect(route.missingText == "Dolphin is not installed")

        // Xbox and Switch have no core on the buildbot for Apple silicon
        let xbox = ConsoleCatalog.console("xbox")!
        #expect(!xbox.hasCore && !ConsoleCatalog.console("switch")!.hasCore)
        #expect(ConsoleRoute.resolve(xbox, choice: "xemu", installed: [], coreReady: true).missingText == "xemu is not installed")
        #expect(ConsoleRoute.resolve(xbox, choice: nil, installed: [], coreReady: false).missingText == "xemu is not installed")
        #expect(ConsoleRoute.resolve(ConsoleCatalog.console("switch")!, choice: EmulatorChoice.retroArch, installed: [],
                                     coreReady: false).missingText == "Ryubing is not installed")
    }

    @MainActor
    @Test func theShelfFallsBackOnlyWhenTheCoreIsHere() async throws {
        let work = try scratchFolder("fallback")
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appending(path: "Applications", directoryHint: .isDirectory)
        let dolphinApp = try FakeEmulators.app("Dolphin", in: applications, bundleID: "org.dolphin-emu.dolphin", version: "2509")
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let shelf = EmulatorShelf(paths: paths, detector: EmulatorDetector(folders: [applications]))
        let gamecube = ConsoleCatalog.console("gamecube")!
        await shelf.refresh()
        shelf.choose("dolphin", for: gamecube)
        #expect(shelf.route(for: gamecube).emulator?.title == "Dolphin 2509")

        try FileManager.default.removeItem(at: dolphinApp)
        await shelf.refresh()
        #expect(shelf.route(for: gamecube).missingText == "Dolphin is not installed")
        #expect(shelf.options(for: gamecube).map(\.title) == ["RetroArch (Dolphin)", "Dolphin (not installed)"])

        try FileManager.default.createDirectory(at: paths.cores, withIntermediateDirectories: true)
        try Data("core".utf8).write(to: paths.cores.appending(path: "dolphin_libretro.dylib"))
        #expect(shelf.route(for: gamecube) == .retroArch)
    }

    @MainActor
    @Test func theChoiceIsKeptPerConsoleInCartouchesFolder() async throws {
        let work = try scratchFolder("choices")
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appending(path: "Applications", directoryHint: .isDirectory)
        try FakeEmulators.app("PPSSPPSDL", in: applications, bundleID: "org.ppsspp.ppsspp", version: "1.20.4")
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let shelf = EmulatorShelf(paths: paths, detector: EmulatorDetector(folders: [applications]))
        await shelf.refresh()
        let psp = ConsoleCatalog.console("psp")!
        #expect(shelf.options(for: psp).map(\.title) == ["RetroArch (PPSSPP)", "PPSSPP 1.20.4"])
        #expect(shelf.selected(for: psp) == "ppsspp")
        shelf.choose(EmulatorChoice.retroArch, for: psp)
        #expect(shelf.route(for: psp) == .retroArch)

        let again = EmulatorShelf(paths: paths, detector: EmulatorDetector(folders: [applications]))
        await again.refresh()
        #expect(again.route(for: psp) == .retroArch)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: paths.emulatorChoices)) == ["psp": "retroarch"])
    }

    // MARK: Launch

    @Test func dolphinStartsTheHomebrewInBatchModeAndQuittingEndsIt() async throws {
        let work = try scratchFolder("launch")
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appending(path: "Applications", directoryHint: .isDirectory)
        try FakeEmulators.app("Dolphin", in: applications, bundleID: "org.dolphin-emu.dolphin", version: "2509")
        let game = work.appending(path: "Games/Cartouche Homebrew.dol")
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FakeEmulators.homebrewDOL().write(to: game)
        let args = work.appending(path: "args.txt"), quit = work.appending(path: "quit")

        let installed = try #require(EmulatorDetector(folders: [applications]).installed().first)
        let route = ConsoleRoute.resolve(ConsoleCatalog.console("gamecube")!, choice: "dolphin", installed: [installed], coreReady: false)
        #expect(route.emulator == installed)
        let player = StandalonePlayer(emulator: installed, environment: FakeEmulators.environment(args: args, quit: quit),
                                      log: work.appending(path: "logs/dolphin.log"))
        try await player.play(PlayRequest(core: installed.executable, content: game))
        #expect(await player.isPlaying)
        #expect(FakeEmulators.arguments(args) == ["-b", "-e", game.path])
        #expect(await player.ended() == nil)

        // The user quits Dolphin
        try Data().write(to: quit)
        var report: PlayReport?
        for _ in 0..<100 where report == nil {
            try await Task.sleep(for: .milliseconds(20))
            report = await player.ended()
        }
        let ended = try #require(report)
        #expect(ended.played > .zero)
        #expect(await !player.isPlaying)
        #expect(await player.ended() == nil, "the end is told once")
    }

    @Test func quitFromCartoucheStopsTheEmulator() async throws {
        let work = try scratchFolder("quit")
        defer { try? FileManager.default.removeItem(at: work) }
        try FakeEmulators.app("PCSX2", in: work, bundleID: "net.pcsx2.pcsx2", version: "2.6.3")
        let installed = try #require(EmulatorDetector(folders: [work]).installed().first)
        let player = StandalonePlayer(
            emulator: installed,
            environment: FakeEmulators.environment(args: work.appending(path: "args.txt"), quit: work.appending(path: "never")))
        await player.setQuitLimits(polite: .milliseconds(200), term: .seconds(2))
        try await player.play(PlayRequest(core: installed.executable, content: work.appending(path: "game.iso")))
        let pid = try #require(await player.processIdentifier)
        let report = await player.quit()
        #expect(report.stop.way == .terminated)
        #expect(kill(pid, 0) != 0, "the emulator is gone")
    }

    @Test func anEmulatorThatFailsAtOnceSaysSo() async throws {
        let work = try scratchFolder("fail")
        defer { try? FileManager.default.removeItem(at: work) }
        try FakeEmulators.app("xemu", in: work, bundleID: "xemu.app.0", version: "0.8.137")
        let installed = try #require(EmulatorDetector(folders: [work]).installed().first)
        var environment = ProcessInfo.processInfo.environment
        environment[FakeEmulators.exitKey] = "3"
        let player = StandalonePlayer(emulator: installed, environment: environment)
        await #expect(throws: StandaloneError.exitedEarly(emulator: "xemu", status: 3)) {
            try await player.play(PlayRequest(core: installed.executable, content: work.appending(path: "game.iso")))
        }
        #expect(await !player.isPlaying)
    }

    // Exit 0 in the startup window means a single-instance emulator handed the
    // game to a copy already open: the session is over before it started
    @Test func anEmulatorThatHandsOffIsNotPlaying() async throws {
        let work = try scratchFolder("handoff")
        defer { try? FileManager.default.removeItem(at: work) }
        try FakeEmulators.app("PCSX2", in: work, bundleID: "net.pcsx2.pcsx2", version: "2.6.3")
        let installed = try #require(EmulatorDetector(folders: [work]).installed().first)
        var environment = ProcessInfo.processInfo.environment
        environment[FakeEmulators.exitKey] = "0"
        let player = StandalonePlayer(emulator: installed, environment: environment)
        await #expect(throws: StandaloneError.handedOff(emulator: "PCSX2")) {
            try await player.play(PlayRequest(core: installed.executable, content: work.appending(path: "game.iso")))
        }
        #expect(await !player.isPlaying)
        #expect(await player.ended() == nil)
    }
}
