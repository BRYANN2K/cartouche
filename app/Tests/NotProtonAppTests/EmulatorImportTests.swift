import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("Emulator preparation during import")
@MainActor
struct EmulatorImportTests {
    private func game(_ scene: ConsoleScene) throws -> ConsoleGame {
        let rom = scene.work.appending(path: "Homebrew.nro")
        try Data("NRO0".utf8).write(to: rom)
        return ConsoleGame(console: "switch", name: "Homebrew", databaseName: nil, file: rom, identifiedBy: .chosen)
    }

    private func installer(_ applications: URL, calls: Box<Int>) -> @Sendable (StandaloneEmulator) async throws -> InstalledEmulator {
        { emulator in
            await MainActor.run { calls.value += 1 }
            let app = try FakeEmulatorApp.install(emulator.executableName, bundleID: emulator.bundleIDs[0], version: "test", in: applications)
            guard let installed = EmulatorDetector.read(app) else { throw URLError(.cannotCreateFile) }
            return installed
        }
    }

    @Test("Import into an already added Switch installs its missing emulator before publishing the game")
    func alreadyAddedConsole() async throws {
        let scene = try await ConsoleScene("auto-emulator")
        defer { scene.remove() }
        await scene.center.add(["switch"])
        let calls = Box(0)
        let install = installer(scene.applications, calls: calls)
        scene.center.installEmulator = { emulator in
            try await Task.sleep(for: .milliseconds(100))
            return try await install(emulator)
        }
        let game = try game(scene)
        let importing = Task { await scene.center.addGames([game]) }
        for _ in 0..<100 where scene.center.preparing.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!scene.center.preparing.isEmpty)
        #expect(scene.center.game(game.id) == nil)
        let added = await importing.value
        #expect(added.map(\.id) == [game.id])
        #expect(scene.center.game(game.id) != nil)
        #expect(scene.center.emulators.route(for: ConsoleCatalog.console("switch")!).emulator?.id == "eden")
        #expect(calls.value == 1)
        await scene.center.addGames([game])
        #expect(calls.value == 1)
        #expect(scene.center.preparing.isEmpty)
    }

    @Test("A failed download leaves the game out of the library; retry can complete")
    func failureAndRetry() async throws {
        let scene = try await ConsoleScene("auto-emulator-retry")
        defer { scene.remove() }
        scene.center.installEmulator = { _ in throw URLError(.notConnectedToInternet) }
        let game = try game(scene)
        #expect(await scene.center.addGames([game]).isEmpty)
        #expect(scene.center.game(game.id) == nil)
        #expect(scene.center.problem != nil)
        #expect(scene.center.preparing.isEmpty)
        scene.center.installEmulator = installer(scene.applications, calls: Box(0))
        #expect(await scene.center.addGames([game]).count == 1)
        #expect(scene.center.problem == nil)
    }

    @Test("An existing Switch emulator is reused instead of downloading a replacement")
    func reuse() async throws {
        let scene = try await ConsoleScene("auto-emulator-reuse")
        defer { scene.remove() }
        try FakeEmulatorApp.install("Ryujinx", bundleID: "org.ryujinx.Ryujinx", version: "1.3", in: scene.applications)
        scene.center.installEmulator = { _ in throw URLError(.notConnectedToInternet) }
        let imported = try game(scene)
        #expect(await scene.center.addGames([imported]).count == 1)
        #expect(scene.center.emulators.route(for: ConsoleCatalog.console("switch")!).emulator?.id == "ryubing")
    }

    @Test("Canceling preparation does not import the game")
    func cancellation() async throws {
        let scene = try await ConsoleScene("auto-emulator-cancel")
        defer { scene.remove() }
        scene.center.installEmulator = { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.cancelled)
        }
        let game = try game(scene)
        let task = Task { await scene.center.addGames([game]) }
        for _ in 0..<100 where scene.center.preparing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        #expect(await task.value.isEmpty)
        #expect(scene.center.game(game.id) == nil)
        #expect(scene.center.preparing.isEmpty)
    }

    @Test("A chosen standalone emulator is installed even when a fallback core is already available")
    func chosenEmulator() async throws {
        let scene = try await ConsoleScene("auto-emulator-choice")
        defer { scene.remove() }
        await scene.center.add(["gamecube"])
        let console = try #require(ConsoleCatalog.console("gamecube"))
        scene.center.emulators.choose("dolphin", for: console)
        let calls = Box(0)
        scene.center.installEmulator = installer(scene.applications, calls: calls)
        let file = scene.work.appending(path: "Homebrew.dol")
        try Data().write(to: file)
        let game = ConsoleGame(console: "gamecube", name: "Homebrew", databaseName: nil, file: file, identifiedBy: .chosen)
        #expect(await scene.center.addGames([game]).count == 1)
        #expect(calls.value == 1)
        #expect(scene.center.route(for: console).emulator?.id == "dolphin")
    }
}
