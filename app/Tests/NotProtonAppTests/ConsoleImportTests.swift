import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Adding console games through the + sheet", .serialized)
@MainActor
struct ConsoleImportTests {

    // The user's own files, here synthetic homebrew written by the test
    private func drop(_ scene: ConsoleScene) throws -> [URL] {
        let folder = scene.work.appending(path: "Drop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cart = folder.appending(path: "my_dump.sfc")
        try ConsoleFixtures.homebrewSNES().write(to: cart)
        let unknown = folder.appending(path: "my_homebrew.gba")
        try ConsoleFixtures.homebrewGBA(title: "MY HOMEBREW").write(to: unknown)
        return [cart, unknown]
    }

    private func sheet(_ scene: ConsoleScene, _ kind: AddGamesKind = .consoles) -> some View {
        AddGamesSheet(kind: kind, library: scene.library).environment(scene.center)
    }

    @Test("Known cartridge: named from the database, its console and \"checksum match\" within 2 seconds")
    func knownCartridge() async throws {
        let scene = try await ConsoleScene("known")
        defer { scene.remove() }
        let files = try drop(scene)
        let host = UIHost(sheet(scene), size: CGSize(width: 560, height: 420))
        defer { host.close() }
        await host.settle()
        let asked = ContinuousClock.now
        scene.center.importFlow.start([files[0]])
        #expect(try await host.wait(for: "1 game identified", within: .seconds(2)))
        let took = ContinuousClock.now - asked
        let texts = try host.texts(named: "import-known")
        #expect(seen(texts, "Cartouche Homebrew"))
        #expect(seen(texts, "Super Nintendo, checksum match"))
        #expect(took < .seconds(2))
        print("evidence: dropped my_dump.sfc, listed \(texts.filter { $0.contains("Homebrew") || $0.contains("checksum") }) after \(took)")
    }

    @Test("Unknown file: \"Not recognized\" with a console picker, and Add leaves it out until a console is chosen")
    func unknownFile() async throws {
        let scene = try await ConsoleScene("unknown")
        defer { scene.remove() }
        let files = try drop(scene)
        let flow = ConsoleImport(identifier: scene.center.identifier)
        let host = UIHost(ConsoleImportFlow(center: scene.center, kind: .constant(.consoles), flow: flow)
            .environment(scene.center), size: CGSize(width: 560, height: 460))
        defer { host.close() }
        flow.start(files)
        await flow.finish()
        await host.settle()
        let texts = try host.texts(named: "import-identified")
        #expect(seen(texts, "my_homebrew"))
        #expect(seen(texts, "Not recognized"))
        #expect(seen(texts, "Choose console"))
        #expect(seen(texts, "Add 1 Game"))
        #expect(seen(texts, "Also adds Super Nintendo to your consoles, with Snes9x."))

        let unknown = try #require(flow.rows.compactMap(\.found).first { !$0.isRecognized })
        #expect(unknown.candidates == ["gba"])
        #expect(flow.games.map(\.name) == ["Cartouche Homebrew"])
        #expect(flow.addTitle == "Add 1 Game")

        flow.chosen[unknown.id] = "gba"
        #expect(flow.games.map(\.name) == ["Cartouche Homebrew", "my_homebrew"])
        #expect(flow.addTitle == "Add 2 Games")
        await host.settle()
        #expect(seen(try host.texts(), "Add 2 Games"))
        let dark = UIHost(ConsoleImportFlow(center: scene.center, kind: .constant(.consoles), flow: flow),
                          size: CGSize(width: 560, height: 460), dark: true)
        await dark.settle()
        _ = try dark.texts(named: "import-identified")
        let games = flow.games
        // Closing a sheet resets its flow
        dark.close()

        // Add downloads the two consoles' cores and puts the games in their consoles
        #expect(flow.rows.isEmpty)
        await scene.center.addGames(games)
        #expect(scene.library.consoles == ["snes", "gba"])
        #expect(scene.coresFolder == ["mgba_libretro.dylib", "snes9x_libretro.dylib"])
        #expect(scene.library.games(in: .source(.console("snes"))).map(\.name) == ["Cartouche Homebrew"])
        #expect(scene.library.games(in: .source(.console("gba"))).map(\.name) == ["my_homebrew"])
        #expect(scene.center.games.first { $0.console == "gba" }?.identifiedBy == .chosen)
    }

    @Test("Disc image: a .cue with its .bin is known by its disc ID, and an .m3u set is one game")
    func discImage() async throws {
        let scene = try await ConsoleScene("disc")
        defer { scene.remove() }
        let folder = scene.work.appending(path: "Discs", directoryHint: .isDirectory)
        try ConsoleFixtures.disc("Test Disc", serial: "SLUS_999.01", in: folder)
        let saga = folder.appending(path: "Saga", directoryHint: .isDirectory)
        try ConsoleFixtures.disc("Saga (Disc 1)", serial: "SLUS_999.02", in: saga)
        try ConsoleFixtures.disc("Saga (Disc 2)", serial: "SLUS_999.03", in: saga)
        try "Saga (Disc 1).cue\nSaga (Disc 2).cue\n".write(to: saga.appending(path: "Saga.m3u"), atomically: true, encoding: .utf8)

        let flow = ConsoleImport(identifier: scene.center.identifier)
        flow.start([folder])
        await flow.finish()
        let found = flow.rows.compactMap(\.found)
        #expect(found.map(\.name) == ["Cartouche Test Saga", "Cartouche Test Disc"])
        #expect(found.allSatisfy { $0.identifiedBy == .discID && $0.console == "ps1" })
        #expect(found.first?.discs.count == 2)
        let host = UIHost(ConsoleImportFlow(center: scene.center, kind: .constant(.consoles), flow: flow), size: CGSize(width: 560, height: 420))
        defer { host.close() }
        await host.settle()
        let texts = try host.texts(named: "import-discs")
        #expect(seen(texts, "PlayStation, disc ID"))
        #expect(seen(texts, "2 games identified"))
        await scene.center.addGames(flow.games)
        let saga1 = try #require(scene.center.games.first { $0.name == "Cartouche Test Saga" })
        #expect(saga1.isMultiDisc)
        #expect(saga1.fileURL.lastPathComponent == "Saga.m3u")
        print("evidence: \(found.map { "\($0.file.lastPathComponent) -> \($0.name), \(ConsoleImport.line($0)), \($0.discs.count) discs" })")
    }

    @Test("Detected console imports support Back without separate game-kind controls")
    func backAndForth() async throws {
        let scene = try await ConsoleScene("switch")
        defer { scene.remove() }
        let files = try drop(scene)
        let flow = scene.center.importFlow
        let host = UIHost(sheet(scene), size: CGSize(width: 560, height: 460))
        defer { host.close() }
        await host.settle()
        let texts = try host.texts(named: "add-games-console-first")
        #expect(seen(texts, "Drop files or a folder here"))
        #expect(!seen(texts, "Windows Game"))
        flow.start(files)
        #expect(try await host.wait(for: "game identified"))
        flow.reset()
        await host.settle()
        #expect(flow.step == .drop && flow.rows.isEmpty && !flow.checking)
        flow.start(files)
        #expect(try await host.wait(for: "1 game identified"))
        #expect(flow.done && flow.games.count == 1)
    }

}
