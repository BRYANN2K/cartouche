import AppKit
import CryptoKit
import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("BIOS warning and Look", .serialized)
@MainActor
struct BIOSLookTests {

    private func panel(_ scene: ConsoleScene, _ id: String, compat: CompatibilityModel) throws -> some View {
        GamePanel(game: try #require(scene.library.game(id)), model: scene.library, compat: compat,
                  actions: GameActionRunner(model: scene.library, open: { _ in }))
            .environment(scene.center).environment(\.covers, scene.covers)
            .frame(width: 360, height: 760)
    }

    @Test("Missing BIOS blocks Play: the panel names the file and says to dump it from your own console")
    func missingBIOS() async throws {
        let scene = try await ConsoleScene("bios")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("PS"))
        let game = try await scene.addGame(console: "ps1", name: "Test Disc", ext: "cue")
        let compat = try await fixtureCompat(scene.work, defaults: scene.scratch)
        let system = try #require(scene.center.console(of: game))
        let content = ConsolePanelContent(game: game, console: system, states: [], bios: await scene.center.bios(for: game), playing: nil)
        #expect(content.biosWarning?.title == "scph5501.bin is missing")
        #expect(content.biosWarning?.detail == "Dump it from your own console, then put it in the BIOS folder.")
        #expect(!content.canPlay)

        var texts: [String] = []
        for dark in [false, true] {
            texts = try await renderedTexts(try panel(scene, game.id, compat: compat), size: CGSize(width: 360, height: 760),
                                            named: "console-panel-bios-missing", dark: dark)
        }
        #expect(seen(texts, "scph5501.bin is missing"))
        #expect(seen(texts, "Dump it from your own console"))
        #expect(!texts.contains { $0.contains("http") || $0.lowercased().contains("download") })

        // Play does nothing without it
        await scene.center.play(game.id, reduceMotion: true)
        #expect(await runner.requests.isEmpty)
        #expect(scene.center.problem == "scph5501.bin is missing")
        print("evidence: PS1 without BIOS, panel reads \(texts.filter { $0.contains("scph") || $0.contains("Dump") }), Play refused: \(scene.center.problem ?? "-")")

        // The user's own dump in the BIOS folder: the core's .info gives its MD5
        let dump = Data(repeating: 0xB1, count: 512 * 1024)
        try dump.write(to: scene.paths.bios.appending(path: "scph5501.bin"))
        let md5 = Insecure.MD5.hash(data: dump).map { String(format: "%02x", $0) }.joined()
        try ConsoleFixtures.info("swanstation", firmware: [("scph5501.bin", md5)])
            .write(to: scene.paths.coreInfo.appending(path: "swanstation_libretro.info"))
        let ready = ConsolePanelContent(game: game, console: system, states: [], bios: await scene.center.bios(for: game), playing: nil)
        #expect(ready.biosWarning == nil && ready.canPlay)
        await scene.center.play(game.id, reduceMotion: true)
        #expect(await runner.requests.count == 1)
        await scene.center.quit()
    }

    @Test("Look applies live: switching to CRT while playing goes to RetroArch, and the panel's picture takes the same look")
    func lookLive() async throws {
        let scene = try await ConsoleScene("look")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("GAME"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        let snap = scene.covers.consoleThumbnails.cached(system: "Nintendo - Super Nintendo Entertainment System", kind: .snap,
                                                         name: "Cartouche Homebrew (World)")
        try FileManager.default.createDirectory(at: snap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConsoleCoverTests.png(width: 256, height: 224, colour: NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)).write(to: snap)
        let compat = try await fixtureCompat(scene.work, defaults: scene.scratch)

        func heroRows() async throws -> [CGFloat] {
            let host = UIHost(try panel(scene, game.id, compat: compat).ignoresSafeArea(), size: CGSize(width: 360, height: 760))
            await host.settle(0.6)
            let bitmap = try host.bitmap()
            host.close()
            let scale = CGFloat(bitmap.pixelsWide) / 360
            // Down the middle of the 170-point picture
            return (60..<84).compactMap { y in
                bitmap.colorAt(x: Int(180 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB)?.blueComponent
            }
        }
        let plain = try await heroRows()

        await scene.center.play(game.id, reduceMotion: true)
        await scene.center.setSetup(game.id) { $0.look = .crt }
        #expect(await runner.looks == [.crt])
        let crt = try await heroRows()
        let spread = { (rows: [CGFloat]) in (rows.max() ?? 0) - (rows.min() ?? 0) }
        #expect(spread(plain) < 0.05)
        #expect(spread(crt) > 0.1, "no scanlines on the panel's picture: \(crt)")
        _ = try await renderedTexts(try panel(scene, game.id, compat: compat), size: CGSize(width: 360, height: 760),
                                    named: "console-panel-crt")
        print("evidence: Look CRT sent to RetroArch (\(await runner.looks)); panel picture row spread \(spread(plain)) -> \(spread(crt))")

        // Not playing: kept for the next start, nothing sent
        await scene.center.quit()
        await scene.center.setSetup(game.id) { $0.look = .lcd }
        #expect(await runner.looks == [.crt])
        await scene.center.play(game.id, reduceMotion: true)
        #expect(await runner.requests.last?.look == .lcd)
        await scene.center.quit()
    }

    // The same switch on a real RetroArch, timed
    @Test("Look applies on RetroArch within a second", .enabled(if: LiveRetroArch.available && LiveRetroArch.video != "null",
                                                               "set CARTOUCHE_RETROARCH, CARTOUCHE_TEST_CORE and CARTOUCHE_RETROARCH_VIDEO=gl"))
    func lookOnRetroArch() async throws {
        let scene = try await ConsoleScene("look-live")
        defer { scene.remove() }
        let player = await LiveRetroArch.player(scene)
        scene.center.makeRunner = { _ in player }
        scene.center.resolveCore = { _ in LiveRetroArch.core! }
        let game = try await scene.addGame(console: "snes", name: "Test Cart", data: LiveRetroArch.cartridge(), ext: "ctc")
        await scene.center.play(game.id, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(400))
        let asked = ContinuousClock.now
        await scene.center.setSetup(game.id) { $0.look = .crt }
        let took = ContinuousClock.now - asked
        #expect(scene.center.problem == nil)
        #expect(took < .seconds(1))
        let session = try #require(await player.session)
        try await session.setOption("pause", on: true)
        let screen = try await session.screenshot()
        let spread = try ContinueFromTests.rowSpread(screen)
        #expect(spread > 20, "no scanlines on RetroArch's screen")
        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"] {
            try screen.write(to: URL(fileURLWithPath: folder).appending(path: "retroarch-crt-from-panel.png"))
        }
        print("evidence: app Look CRT on RetroArch applied in \(took), screen row spread \(spread), status \(try await session.status().state)")
        await scene.center.quit()
    }
}
