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
        let scene = try await ConsoleScene("panel-order")
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

        let disc = try await scene.addGame(console: "ps1", name: "Saga", discs: 2)
        let ps1 = try #require(scene.center.console(of: disc))
        let warned = ConsolePanelContent(game: disc, console: ps1, states: [], bios: await scene.center.bios(for: disc), playing: nil)
        #expect(warned.titles == ["Play", "BIOS", "Your Play", "Setup", "Controls", "Play Together", "More…"])
        #expect(!warned.canPlay)
    }

    @Test("The panel and its More… sheet render in light and dark")
    func snapshots() async throws {
        let scene = try await ConsoleScene("panel-snap")
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

    // The reported mismatch: states and a save exist from days ago, nothing counted
    // the play, and the panel read "Never played"/"Not yet" under a Resume button.
    @Test("A state or save from before sessions counted still reads as played, and the labels agree")
    func playedIsConsistent() async throws {
        let scene = try await ConsoleScene("panel-played")
        defer { scene.remove() }
        let added = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        let system = try #require(scene.center.console(of: added))

        // A 7-day-old auto state and an older SRAM save, no session ever counted
        try scene.writeState(added, slot: nil, picture: try Self.screen("AUTO"), age: 7 * 86400)
        try scene.writeSave(added, age: 30 * 86400)
        await scene.center.reload()

        let game = try #require(scene.center.game(added.id))
        #expect(game.lastPlayed != nil, "the save files' newest date stands in for the uncounted play")
        let content = ConsolePanelContent(game: game, console: system, states: await scene.center.states(for: game),
                                        bios: await scene.center.bios(for: game), playing: nil)
        // The button, the subtitle and the Played row describe the same fact
        #expect(content.playLabel == "Resume")
        #expect(content.playedAt != nil)
        #expect(content.subtitle() == "Super Nintendo. Played 7 days ago.")
        #expect(content.played == "7 days ago")
        // So does the library row
        #expect(scene.library.game(game.id)?.status() == "Played 7 days ago")

        // A save alone, with no state at all, still says the game ran
        let sramOnly = try await scene.addGame(console: "snes", name: "SRAM Only",
                                             data: ConsoleFixtures.homebrewSNES(title: "SRAM ONLY", fill: 0x99))
        try scene.writeSave(sramOnly, age: 3 * 86400)
        await scene.center.reload()
        let merged = try #require(scene.center.game(sramOnly.id))
        let save = ConsolePanelContent(game: merged, console: system, states: [], bios: nil, playing: nil)
        #expect(save.playLabel == "Play")
        #expect(save.subtitle() == "Super Nintendo. Played 3 days ago.")
        #expect(save.played == "3 days ago")

        // A counted session newer than the files wins
        try await scene.center.store.update(added.id) { $0.lastPlayed = Date() }
        await scene.center.reload()
        let now = try #require(scene.center.game(added.id))
        let today = ConsolePanelContent(game: now, console: system, states: await scene.center.states(for: added),
                                        bios: await scene.center.bios(for: added), playing: nil)
        #expect(today.subtitle() == "Super Nintendo. Played today.")
        #expect(today.played == "today")
    }

    @Test("A multi-disc game offers its discs; Setup changes are kept for the game")
    func setupIsKept() async throws {
        let scene = try await ConsoleScene("panel-setup")
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
