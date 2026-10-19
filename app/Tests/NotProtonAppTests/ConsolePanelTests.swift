import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Console game panel", .serialized)
@MainActor
struct ConsolePanelTests {

    static func screen(_ text: String, hue: Double = 0.6) throws -> Data {
        try SteamFixture.png(text, size: CGSize(width: 256, height: 224), hue: hue)
    }

    private func panel(_ scene: ConsoleScene, _ id: String, compat: CompatibilityModel) throws -> some View {
        let game = try #require(scene.library.game(id))
        return GamePanel(game: game, model: scene.library, compat: compat,
                         actions: GameActionRunner(model: scene.library, open: { _ in }))
            .environment(scene.center)
            .environment(\.covers, scene.covers)
            .frame(width: 360, height: 980)
    }

    @Test("Sections in the documented order: Play or Resume, Continue From, play time and achievements, Setup, Controls, Play Together, More…")
    func order() async throws {
        let scene = try ConsoleScene("panel-order")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        let system = try #require(scene.center.console(of: game))

        var content = ConsolePanelContent(game: game, console: system, states: [], bios: await scene.center.bios(for: game), playing: nil)
        #expect(content.titles == ["Play", "Your Play", "Setup", "Controls", "Play Together", "More…"])
        #expect(content.played == "Not yet")
        #expect(content.subtitle() == "Super Nintendo. Never played.")

        try scene.writeState(game, slot: 3, picture: try Self.screen("SLOT 3"), age: 3600)
        try scene.writeState(game, slot: nil, picture: try Self.screen("AUTO"), age: 60)
        content = ConsolePanelContent(game: game, console: system, states: await scene.center.states(for: game),
                                      bios: await scene.center.bios(for: game), playing: nil)
        #expect(content.titles == ["Resume", "Continue From", "Your Play", "Setup", "Controls", "Play Together", "More…"])
        #expect(content.states.map(\.title) == ["Auto", "Slot 3"])
        #expect(content.cores.map(\.name) == ["Snes9x", "bsnes", "Mesen-S"])

        // A PlayStation game without its BIOS: the warning comes under Play
        let disc = try await scene.addGame(console: "ps1", name: "Saga", discs: 2)
        let ps1 = try #require(scene.center.console(of: disc))
        let warned = ConsolePanelContent(game: disc, console: ps1, states: [], bios: await scene.center.bios(for: disc), playing: nil)
        #expect(warned.titles == ["Play", "BIOS", "Your Play", "Setup", "Controls", "Play Together", "More…"])
        #expect(!warned.canPlay)
    }

    @Test("The panel and its More… sheet render in light and dark")
    func snapshots() async throws {
        let scene = try ConsoleScene("panel-snap")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        try await scene.center.store.update(game.id) { $0.playSeconds = 7.5 * 3600; $0.setup.look = .crt }
        await scene.center.reload()
        for (slot, age, text) in [(nil, 120.0, "AUTO"), (3, 7200.0, "SLOT 3"), (1, 90000.0, "SLOT 1")] as [(Int?, Double, String)] {
            try scene.writeState(game, slot: slot, picture: try Self.screen(text, hue: Double(slot ?? 0) / 4), age: age)
        }
        // The screenshot from libretro-thumbnails, already in the cache
        let snap = scene.covers.consoleThumbnails.cached(system: "Nintendo - Super Nintendo Entertainment System", kind: .snap,
                                                         name: "Cartouche Homebrew (World)")
        try FileManager.default.createDirectory(at: snap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.screen("HOMEBREW", hue: 0.3).write(to: snap)
        let compat = try await fixtureCompat(scene.work, defaults: scene.scratch)
        for dark in [false, true] {
            let texts = try await renderedTexts(try panel(scene, game.id, compat: compat), size: CGSize(width: 360, height: 980),
                                                named: "console-panel", dark: dark, settle: 0.8)
            for wanted in ["Cartouche Homebrew", "Resume", "Continue From", "Auto", "Slot 3", "Played", "hours",
                           "Achievements", "Setup", "Core", "Look", "Lower input lag", "Hardcore achievements", "Controls", "More"] {
                #expect(seen(texts, wanted), "\(wanted) not drawn (dark: \(dark)): \(texts)")
            }
        }
        let current = try #require(scene.center.game(game.id))
        let system = try #require(scene.center.console(of: current))
        let content = ConsolePanelContent(game: current, console: system,
                                          states: await scene.center.states(for: game), bios: await scene.center.bios(for: game), playing: nil)
        for dark in [false, true] {
            let texts = try await renderedTexts(ConsoleMoreSheet(game: content.game, content: content, center: scene.center),
                                                size: CGSize(width: 480, height: 460), named: "console-more", dark: dark)
            #expect(seen(texts, "Achievements") && seen(texts, "Files") && seen(texts, "Covers from libretro-thumbnails"))
        }
    }

    @Test("A multi-disc game offers its discs; Setup changes are kept for the game")
    func setupIsKept() async throws {
        let scene = try ConsoleScene("panel-setup")
        defer { scene.remove() }
        let game = try await scene.addGame(console: "ps1", name: "Saga", discs: 2)
        try Data(repeating: 1, count: 16).write(to: scene.paths.bios.appending(path: "scph5501.bin"))
        let texts = try await renderedTexts(try panel(scene, game.id, compat: try await fixtureCompat(scene.work, defaults: scene.scratch)), size: CGSize(width: 360, height: 980), named: "console-panel-discs")
        #expect(seen(texts, "Disc"))
        await scene.center.setSetup(game.id) { $0.disc = 1; $0.lowerInputLag = false; $0.core = "pcsx_rearmed" }
        let kept = try #require(await ConsoleLibrary(paths: scene.paths).game(game.id))
        #expect(kept.setup.disc == 1 && !kept.setup.lowerInputLag && kept.setup.core == "pcsx_rearmed")
    }
}
