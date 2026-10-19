import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// One free game per store, installed and played through the library: the download's
// progress in the activity slot, then the runner and graphics backend of the game's
// setup, in the game's own prefix
@Suite("Store games", .serialized)
@MainActor
struct StoreGameTests {

    private func playAndWait(_ scene: StoreScene, _ id: String) async throws {
        let game = try #require(scene.model.game(id))
        let before = scene.text("wine.calls").components(separatedBy: "args:").count
        GameActionRunner(model: scene.model, stores: scene.center).perform(.play, on: game)
        #expect(scene.center.playing.contains(id))
        await scene.waitUntil { !scene.center.playing.contains(id) && scene.text("wine.calls").components(separatedBy: "args:").count > before }
        #expect(scene.center.problem == nil, "\(scene.center.problem ?? "")")
    }

    @Test("Epic: a free game downloads with progress in the activity slot, then plays with the runner and backend of its setup")
    func epic() async throws {
        let scene = try await StoreScene("game-epic")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let game = try #require(scene.model.game("epic:Fennec"))
        #expect(!game.installed)
        #expect(game.artwork == URL(string: "https://cdn1.epicgames.com/tall.jpg"))
        let actions = GameActionRunner(model: scene.model, stores: scene.center)
        actions.perform(.install, on: game)
        var seen: [Double] = []
        await scene.waitUntil {
            if let activity = scene.center.activity { seen.append(activity.fraction); #expect(activity.title == "Sample Free Game") }
            return scene.center.activity == nil && scene.center.record(game.id) != nil
        }
        #expect(seen.contains { $0 > 0 && $0 < 1 }, "\(seen)")
        print("evidence: activity slot fractions while Sample Free Game downloaded: \(Array(Set(seen)).sorted())")
        let installed = try #require(scene.model.game("epic:Fennec"))
        #expect(installed.installed && installed.status() == "Installed")

        // What the panel's Setup shows is what starts the game
        let setup = scene.model.resolution(for: installed).setup
        #expect(setup.runner?.id == scene.runner.id && setup.translation == .rosetta)
        let backend = try #require(setup.backend)
        try await playAndWait(scene, "epic:Fennec")
        let record = try #require(scene.center.record("epic:Fennec"))
        #expect(FileManager.default.fileExists(atPath: record.prefix.appending(path: "system.reg").path))
        var wine = scene.text("wine.calls")
        #expect(wine.contains("wineboot \(record.prefix.path(percentEncoded: false))"))
        #expect(wine.contains("args: \(record.install.path.appending(path: "Binaries/Game.exe").path(percentEncoded: false)) -windowed -AUTH_PASSWORD=exchange-code -epicapp=Fennec"))
        #expect(wine.split(separator: "\n").contains { $0.hasPrefix("pwd: ") && $0.hasSuffix("/Fennec/Binaries") })
        #expect(wine.contains("CX_GRAPHICS_BACKEND=\(backend.rawValue)"))
        #expect(wine.contains("WINEPREFIX=\(record.prefix.path(percentEncoded: false))"))
        #expect(wine.contains("EOS_TEST=1"))
        print("evidence: Epic game started with runner \(scene.runner.displayVersion) and \(backend.label): \(wine.split(separator: "\n").first { $0.hasPrefix("args:") } ?? "")")
        // Cloud saves before and after
        let saves = scene.text("legendary.saves")
        #expect(saves.contains("--skip-upload") && saves.contains("--skip-download"))

        // Another backend picked in the setup is the one the next start gets
        var choice = scene.model.setup(for: installed.id)
        choice.graphics = .dxvk
        choice.environment = ["DXVK_HUD": "fps"]
        scene.model.setSetup(choice, for: installed.id, tellSteam: false)
        #expect(scene.model.resolution(for: installed).setup.backend == .dxvk)
        try await playAndWait(scene, "epic:Fennec")
        wine = scene.text("wine.calls")
        #expect(wine.contains("CX_GRAPHICS_BACKEND=dxvk"))
        #expect(wine.contains("DXVK_HUD=fps"))
        #expect(scene.filesHolding(["epic-access", "epic-refresh"]).isEmpty)
    }

    @Test("GOG: a free game downloads and plays, with comet beside it reading the tokens, which are gone once it ends")
    func gog() async throws {
        let scene = try await StoreScene("game-gog", gogServer: true)
        defer { scene.remove() }
        await scene.center.beginSignIn(.gog)
        await scene.center.finishSignIn(.gog, code: "gog-good-code")
        let game = try #require(scene.model.game("gog:1207658924"))
        scene.center.install(game)
        await scene.waitForJobs()
        let record = try #require(scene.center.record(game.id))
        #expect(record.install.version == "5310700")
        try await playAndWait(scene, game.id)
        let wine = scene.text("wine.calls")
        #expect(wine.contains("args: \(record.install.path.appending(path: "bin/game.exe").path(percentEncoded: false)) -skipintro"))
        #expect(scene.calls("comet") == ["--from-heroic --username galaxy_player --quit"])
        #expect(FileManager.default.fileExists(atPath: scene.state.appending(path: "comet.saw-token").path))
        await scene.waitUntil { FileManager.default.fileExists(atPath: scene.state.appending(path: "comet.stopped").path) }
        #expect(FileManager.default.fileExists(atPath: scene.state.appending(path: "comet.stopped").path))
        #expect(scene.filesHolding(["gog-access", "gog-refresh"]).isEmpty)
        // gogdl's last sync time is kept for the next start
        #expect(scene.center.record(game.id)?.saveStamps == ["saves": "1790000123.5"])
    }

    @Test("Amazon: a free game downloads and plays from its fuel.json, without asking Amazon")
    func amazon() async throws {
        let scene = try await StoreScene("game-amazon")
        defer { scene.remove() }
        await scene.center.beginSignIn(.amazon)
        await scene.center.finishSignIn(.amazon, code: "amazon-good-code")
        let game = try #require(scene.model.game("amazon:amzn1.adg.product.SAMPLE"))
        scene.center.install(game)
        await scene.waitForJobs()
        let record = try #require(scene.center.record(game.id))
        let before = scene.calls("nile").count
        try await playAndWait(scene, game.id)
        #expect(scene.text("wine.calls").contains("args: \(record.install.path.appending(path: "Game/Sample.exe").path(percentEncoded: false)) -prime"))
        #expect(scene.calls("nile").count == before)
    }

    @Test("Update, verify and uninstall go through the store's client; uninstall removes the files and the prefix")
    func manage() async throws {
        let scene = try await StoreScene("game-manage")
        defer { scene.remove() }
        await scene.center.beginSignIn(.amazon)
        await scene.center.finishSignIn(.amazon, code: "amazon-good-code")
        var game = try #require(scene.model.game("amazon:amzn1.adg.product.SAMPLE"))
        let menu = GameMenu.items(for: game, in: scene.model)
        #expect(menu.first?.action == .install && GameMenu.actions(menu).contains(.uninstall))
        var actions = GameActionRunner(model: scene.model, stores: scene.center)
        actions.confirmUninstall = { _ in true }
        actions.perform(.install, on: game)
        await scene.waitForJobs()
        game = try #require(scene.model.game(game.id))
        #expect(GameMenu.actions(GameMenu.items(for: game, in: scene.model)).contains(.update))
        actions.perform(.update, on: game)
        await scene.waitForJobs()
        actions.perform(.verifyFiles, on: game)
        await scene.waitForJobs()
        let record = try #require(scene.center.record(game.id))
        actions.perform(.uninstall, on: game)
        await scene.waitUntil { scene.center.record(game.id) == nil }
        let calls = scene.calls("nile")
        #expect(calls.contains("update amzn1.adg.product.SAMPLE --path \(record.install.path.clientPath)"))
        #expect(calls.contains("verify amzn1.adg.product.SAMPLE --path \(record.install.path.clientPath)"))
        #expect(calls.contains("uninstall amzn1.adg.product.SAMPLE"))
        #expect(!FileManager.default.fileExists(atPath: record.folder.path))
        #expect(scene.model.game(game.id)?.installed == false)
    }

    @Test("A store game's cover is the store's box art, kept in the cover cache for offline")
    func storeCover() async throws {
        let work = try scratchDirectory("store-cover")
        defer { try? FileManager.default.removeItem(at: work) }
        let png = try SteamFixture.png("Sample", size: CGSize(width: 60, height: 90), hue: 0.2)
        let asked = LineLog()
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: { url in asked.add(url.absoluteString); return (png, 200) })
        var game = Game(id: "epic:Fennec", source: .epic, name: "Sample Free Game", installed: false)
        #expect(covers.local(for: game, kind: .cover, override: nil) == nil)
        game.artwork = URL(string: "https://cdn1.epicgames.com/tall.jpg")
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        #expect(asked.all == ["https://cdn1.epicgames.com/tall.jpg"])
        #expect(covers.local(for: game, kind: .hero, override: nil) == .image(file))
        #expect(file.path.hasPrefix(work.appending(path: "covers/store/epic").path))
    }

    @Test("Store games run under Rosetta: no translation choice, whatever the default")
    func rosettaOnly() async throws {
        let scene = try await StoreScene("game-rosetta")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let game = try #require(scene.model.game("epic:Fennec"))
        var choice = scene.model.setup(for: game.id)
        choice.translation = .fex
        scene.model.setSetup(choice, for: game.id, tellSteam: false)
        #expect(scene.model.resolution(for: game).setup.translation == .rosetta)
        #expect(scene.model.translationChoices(for: game) == [.rosetta])
    }

    @Test("Without a runner set up, Play says where to set one up")
    func noRunner() async throws {
        let scene = try await StoreScene("game-norunner")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let game = try #require(scene.model.game("epic:Fennec"))
        scene.center.install(game)
        await scene.waitForJobs()
        scene.model.runners = []
        GameActionRunner(model: scene.model, stores: scene.center).perform(.play, on: try #require(scene.model.game(game.id)))
        #expect(scene.center.problem == "Set up a runner in Settings > Compatibility to play Sample Free Game.")
        #expect(!scene.center.playing.contains(game.id))
    }

    @Test("The store's download joins the sidebar's activity slot, and its Stop ends the job")
    func activitySlot() async throws {
        let scene = try await StoreScene("game-activity")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        scene.flag("slow")
        // The app's wiring in startStores: the center feeds the slot, Stop goes back to it
        let activity = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                      notifier: RecordingActivityNotifier())
        activity.storeSource = { [scene] in scene.center.activity }
        activity.stopStore = { [scene] in scene.center.stop($0) }
        scene.center.install(try #require(scene.model.game("epic:Fennec")))
        await scene.waitUntil { (scene.center.activity?.fraction ?? 0) > 0 }
        let shown = try #require(scene.center.activity)
        #expect(activity.slot == .store(shown))
        #expect(activity.menuSections.map(\.kind) == [.store])
        for dark in [false, true] {
            await windowSnapshot(LibrarySidebar(model: scene.model).activitySlot(activity, library: scene.model),
                                 named: "store-activity", size: CGSize(width: 260, height: 600), dark: dark)
        }
        // Stop on the card cancels the running job, and the game is left uninstalled
        activity.stopStore(shown)
        await scene.waitForJobs()
        #expect(scene.center.activity == nil)
        #expect(scene.center.record("epic:Fennec") == nil)
    }

    @Test("The store card shows the job's label, the game, the percent and Stop")
    func storeCardTexts() async throws {
        let queued = StoreActivity(gameID: "epic:Owl", title: "Second Game", label: StoreJob.Kind.update.label,
                                   fraction: 0.5, waiting: 1)
        for (activity, label, percent, extra) in [
            (epicDownload, "Downloading", "34", String?.none),
            (queued, "Updating", "50", "1 more waiting"),
        ] {
            let texts = try await renderedTexts(
                StoreInstallCard(activity: activity, stop: {}, show: {}).frame(width: 220).padding(12),
                size: CGSize(width: 240, height: 90))
            #expect(seen(texts, label), "\(texts)")
            #expect(seen(texts, activity.title), "\(texts)")
            #expect(seen(texts, "Stop"), "\(texts)")
            #expect(seen(texts, percent) || seen(texts, "\(percent)%"), "\(texts)")
            if let extra { #expect(seen(texts, extra), "\(texts)") }
        }
    }
}
