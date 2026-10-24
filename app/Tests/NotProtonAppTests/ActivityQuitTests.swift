import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Launch, activity slot and Quit", .serialized)
@MainActor
struct ActivityQuitTests {

    private func sidebar(_ scene: ConsoleScene) -> some View {
        let activity = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                      notifier: RecordingActivityNotifier())
        activity.follow(scene.center)
        return LibrarySidebar(model: scene.library).activitySlot(activity, library: scene.library)
            .environment(scene.center).environment(\.covers, scene.covers)
            .frame(width: 280, height: 560)
    }

    @Test("Play: a CRT power-on, then the game shows as playing in the activity slot with Quit")
    func launch() async throws {
        let scene = try await ConsoleScene("launch")
        defer { scene.remove() }
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew", databaseName: "Cartouche Homebrew (World)")
        let snap = scene.covers.consoleThumbnails.cached(system: "Nintendo - Super Nintendo Entertainment System", kind: .snap,
                                                         name: "Cartouche Homebrew (World)")
        try FileManager.default.createDirectory(at: snap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConsolePanelTests.screen("HOMEBREW", hue: 0.3).write(to: snap)

        #expect(!seen(try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560)), "Quit"))
        await scene.center.play(game.id)
        #expect(scene.center.playing == Playing(gameID: game.id, phase: .playing))
        #expect(scene.center.powerOn == PowerOn(gameID: game.id, picture: snap))

        var cleared = false
        let crt = UIHost(CRTPowerOn(powerOn: try #require(scene.center.powerOn)) { cleared = true }.frame(width: 640, height: 400),
                         size: CGSize(width: 640, height: 400))
        await crt.settle(0.7)
        _ = try crt.texts(named: "crt-power-on")
        let lit = try crt.bitmap()
        let middle = try #require(lit.colorAt(x: lit.pixelsWide / 2, y: lit.pixelsHigh / 2))
        #expect(middle.brightnessComponent > 0.1, "the picture did not open: \(middle)")
        await crt.settle(1.2)
        crt.close()
        #expect(cleared)

        let texts = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560), named: "activity-slot-playing")
        _ = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560), named: "activity-slot-playing", dark: true)
        #expect(seen(texts, "Playing"))
        #expect(seen(texts, "Cartouche Homebrew"))
        #expect(seen(texts, "Quit"))
        print("evidence: after Play, activity slot reads \(texts.suffix(3)), power-on picture \(snap.lastPathComponent)")
        await scene.center.quit()
    }

    @Test("Reduce Motion: no power-on")
    func reduceMotion() async throws {
        let scene = try await ConsoleScene("reduce")
        defer { scene.remove() }
        _ = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.powerOn == nil)
        #expect(scene.center.playing?.phase == .playing)
        await scene.center.quit()
    }

    @Test("Quit from Cartouche: the auto state is written, Continue From shows its picture, play time grows by the session")
    func quit() async throws {
        let scene = try await ConsoleScene("quit")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("QUIT HERE"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        let before = try #require(scene.center.game(game.id)).playSeconds
        await scene.center.play(game.id, reduceMotion: true)
        await runner.pretend(played: .seconds(90))
        await scene.center.quit()

        #expect(await runner.quits == 1)
        #expect(scene.center.playing == nil)
        let after = try #require(scene.center.game(game.id))
        #expect(after.playSeconds - before == 90, "play time grew by \(after.playSeconds - before)")
        #expect(after.lastPlayed != nil)
        let states = await scene.center.states(for: after)
        #expect(states.first?.isAuto == true && states.first?.picture != nil)
        let system = try #require(scene.center.console(of: after))
        let content = ConsolePanelContent(game: after, console: system, states: states, bios: nil, playing: nil)
        #expect(content.titles.first == "Resume")
        #expect(content.titles.contains("Continue From"))
        #expect(!seen(try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 560)), "Quit"))
        print("evidence: Quit -> play time +\(after.playSeconds - before) s, Continue From \(states.map(\.title))")
    }

    @Test("RetroArch closed from its own window ends the session in Cartouche too")
    func endedByItself() async throws {
        let scene = try await ConsoleScene("ended")
        defer { scene.remove() }
        let runner = scene.useFakeRunner(picture: try ConsolePanelTests.screen("AUTO"))
        let game = try await scene.addGame(console: "snes", name: "Cartouche Homebrew")
        await scene.center.play(game.id, reduceMotion: true)
        await runner.exitByItself()
        var waited = 0
        while scene.center.playing != nil, waited < 40 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        #expect(scene.center.playing == nil)
        #expect((scene.center.game(game.id)?.playSeconds ?? 0) > 0)
    }

    @Test("Quit on RetroArch", .enabled(if: LiveRetroArch.available, "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE"))
    func quitOnRetroArch() async throws {
        let scene = try await ConsoleScene("quit-live")
        defer { scene.remove() }
        let player = await LiveRetroArch.player(scene)
        scene.center.makeRunner = { _ in player }
        scene.center.resolveCore = { _ in LiveRetroArch.core! }
        let game = try await scene.addGame(console: "snes", name: "Test Cart", data: LiveRetroArch.cartridge(), ext: "ctc")
        let started = Date()
        await scene.center.play(game.id, reduceMotion: true)
        #expect(scene.center.problem == nil)
        try await Task.sleep(for: .seconds(1.5))
        await scene.center.quit()
        #expect(await !player.isPlaying)
        let after = try #require(scene.center.game(game.id))
        #expect(after.playSeconds >= 1.5 && after.playSeconds < 4)
        let auto = try #require(await scene.center.states(for: after).first { $0.isAuto })
        #expect(auto.date >= started.addingTimeInterval(-1))
        if LiveRetroArch.video != "null" { #expect(auto.picture != nil) }
        print("evidence: RetroArch quit from the activity slot, play time \(after.playSeconds) s, auto state \(auto.file.lastPathComponent) with picture \(auto.picture?.lastPathComponent ?? "none")")
    }
}
