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
        #expect(await scene.waitUntil { !scene.center.playing.contains(id) && scene.text("wine.calls").components(separatedBy: "args:").count > before })
        #expect(scene.center.problem == nil, "\(scene.center.problem ?? "")")
    }

    @Test("Changing runners reuses one installation and preserves saves", arguments: [GameSource.epic, .gog, .amazon])
    func sharedInstallation(source: GameSource) async throws {
        let scene = try await StoreScene("shared-\(source.id)", gogServer: source == .gog)
        defer { scene.remove() }
        await scene.signIn(source, code: "\(source.id)-good-code")
        let ids: [GameSource: String] = [.epic: "epic:Fennec", .gog: "gog:1207658924", .amazon: "amazon:amzn1.adg.product.SAMPLE"]
        let id = try #require(ids[source])
        let game = try #require(scene.model.game(id))
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        try await playAndWait(scene, id)
        let record = try #require(scene.center.record(id))
        let relative: [GameSource: String] = [.epic: "Binaries/Game.exe", .gog: "bin/game.exe", .amazon: "Game/Sample.exe"]
        let executable = record.install.path.appending(path: try #require(relative[source]))
        let before = try executable.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let save = record.prefix.appending(path: "drive_c/users/crossover/Documents/runner-switch.sav")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep this save".utf8).write(to: save)
        let clients = ["legendary", "gogdl", "nile"]
        let downloads = clients.map { scene.calls($0).filter { !Set($0.split(separator: " ")).isDisjoint(with: ["install", "download"]) }.count }
        let alternate = try fakeRunner(in: scene.runners, build: "26.3.0.39832", flavors: [.rosetta])
        let root = SupportPaths.clonedRoot(forBuild: alternate.id, runners: scene.runners)
        let script = StoreStubs.wine(state: scene.state)
        try StoreStubs.install(script.replacingOccurrences(of: "if [ \"$1\" = wineboot ]; then", with: "echo alternate >> '\(scene.state.appending(path: "chosen-runner").path)'\nif [ \"$1\" = wineboot ]; then"), at: root.appending(path: "lib/wine/x86_64-unix/wine"))
        try StoreStubs.install("#!/bin/sh\nexit 0\n", at: root.appending(path: "bin/wineserver"))
        scene.model.runners.append(alternate)
        for runner in [alternate, scene.runner] {
            scene.model.setSetup(GameSetupChoice(runnerID: runner.id, graphics: .wined3d), for: id)
            #expect(scene.center.setup(for: game)?.runner?.id == runner.id)
            try await playAndWait(scene, id)
            #expect(scene.center.record(id)?.install.path == record.install.path)
            #expect(scene.center.record(id)?.prefix == record.prefix)
            #expect(try Data(contentsOf: save) == Data("keep this save".utf8))
        }
        #expect(scene.text("chosen-runner").contains("alternate"))
        let after = try executable.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        #expect(before == after)
        #expect(downloads == clients.map { scene.calls($0).filter { !Set($0.split(separator: " ")).isDisjoint(with: ["install", "download"]) }.count })
    }

    @Test("Epic: the adapter's environment cannot hand MetalFX to a game without DLSS")
    func epicMetalFXFiltered() async throws {
        let scene = try await StoreScene("metalfx")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let game = try #require(scene.model.game("epic:Fennec"))
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        try await playAndWait(scene, "epic:Fennec")
        // legendary's JSON asks for D3DM_ENABLE_METALFX=1; the game ships no DLSS, so it must not land
        let calls = scene.text("wine.calls")
        #expect(calls.contains("D3DM_ENABLE_METALFX=\n"))
        #expect(!calls.contains("D3DM_ENABLE_METALFX=1"))
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
        #expect(scene.model.installRequest?.id == game.id)
        #expect(scene.center.job(for: game.id) == nil)
        scene.center.install(game)
        var seen: [Double] = []
        var titles = Set<String>()
        #expect(await scene.waitUntil {
            if let activity = scene.center.activity { seen.append(activity.fraction); titles.insert(activity.title) }
            return scene.center.activity == nil && scene.center.record(game.id) != nil
        })
        #expect(titles == ["Sample Free Game"])
        #expect(seen.contains { $0 > 0 && $0 < 1 }, "\(seen)")
        print("evidence: activity slot fractions while Sample Free Game downloaded: \(Array(Set(seen)).sorted())")
        let installed = try #require(scene.model.game("epic:Fennec"))
        #expect(installed.installed && installed.status() == "Installed")

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
        // The store's own variables pass the same filter as the setup's: DXVK_ does, HOME does not
        #expect(wine.contains("DXVK_LOG_LEVEL=none"))
        #expect(!wine.contains("HOME=/tmp/legendary-home"))
        print("evidence: Epic game started with runner \(scene.runner.displayVersion) and \(backend.label): \(wine.split(separator: "\n").first { $0.hasPrefix("args:") } ?? "")")
        let saves = scene.text("legendary.saves")
        #expect(saves.contains("--skip-upload") && saves.contains("--skip-download"))

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
        #expect(await scene.waitForJobs())
        let record = try #require(scene.center.record(game.id))
        #expect(record.install.version == "5310700")
        try await playAndWait(scene, game.id)
        let wine = scene.text("wine.calls")
        #expect(wine.contains("args: \(record.install.path.appending(path: "bin/game.exe").path(percentEncoded: false)) -skipintro"))
        #expect(scene.calls("comet") == ["--from-heroic --username galaxy_player --quit"])
        #expect(FileManager.default.fileExists(atPath: scene.state.appending(path: "comet.saw-token").path))
        #expect(await scene.waitUntil { FileManager.default.fileExists(atPath: scene.state.appending(path: "comet.stopped").path) })
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
        #expect(await scene.waitForJobs())
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
        #expect(menu.first?.action == .install && menu.flatMap(\.flatActions).contains(.uninstall))
        var actions = GameActionRunner(model: scene.model, stores: scene.center)
        actions.confirmUninstall = { _, _ in true }
        actions.perform(.install, on: game)
        #expect(scene.model.installRequest?.id == game.id)
        #expect(scene.center.job(for: game.id) == nil)
        scene.center.install(game)
        #expect(await scene.waitForJobs())
        game = try #require(scene.model.game(game.id))
        #expect(GameMenu.items(for: game, in: scene.model).flatMap(\.flatActions).contains(.update))
        actions.perform(.update, on: game)
        #expect(await scene.waitForJobs())
        actions.perform(.verifyFiles, on: game)
        #expect(await scene.waitForJobs())
        let record = try #require(scene.center.record(game.id))
        actions.perform(.uninstall, on: game)
        #expect(await scene.waitUntil { scene.center.record(game.id) == nil })
        let calls = scene.calls("nile")
        #expect(calls.contains("update amzn1.adg.product.SAMPLE --path \(record.install.path.clientPath)"))
        #expect(calls.contains("verify amzn1.adg.product.SAMPLE --path \(record.install.path.clientPath)"))
        #expect(calls.contains("uninstall amzn1.adg.product.SAMPLE"))
        #expect(!FileManager.default.fileExists(atPath: record.folder.path))
        #expect(scene.model.game(game.id)?.installed == false)
    }

    @Test("Recreate Prefix sets the old prefix aside at once and deletes it off the main actor")
    func discardPrefix() async throws {
        let work = try scratchDirectory("discard")
        defer { try? FileManager.default.removeItem(at: work) }
        let prefix = work.appending(path: "prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix.appending(path: "drive_c/windows"), withIntermediateDirectories: true)
        try Data("reg".utf8).write(to: prefix.appending(path: "system.reg"))

        let removal = try #require(StoreCenter.discard(prefix))
        #expect(!FileManager.default.fileExists(atPath: prefix.path))
        await removal.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        #expect(StoreCenter.discard(prefix) == nil)
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

    // A Ubisoft card's cover chain: the launcher's own box art when it really is
    // portrait, the compat match's Steam cover next, the space's tile last. The
    // panel's wide art has its own file so it never clobbers the cover.
    private func ubisoftGame(art: String?, fallback: String = "https://ubiservices.cdn.ubi.com/space-x/ConnectPC/backgroundTileImageId.jpg",
                             compat: Int? = nil, header: String? = nil) -> Game {
        var game = Game(id: "ubisoft:42", source: .ubisoft, name: "Fixture Ubi", installed: false)
        game.artwork = art.flatMap(URL.init)
        game.artworkFallback = URL(string: fallback)
        game.compatAppID = compat
        game.mediaHeader = header.flatMap(URL.init)
        return game
    }

    @Test("Ubisoft cover: the launcher's own box art wins when it downloads portrait")
    func ubisoftCoverPortrait() async throws {
        let work = try scratchDirectory("ubi-cover-portrait")
        defer { try? FileManager.default.removeItem(at: work) }
        let box = try SteamFixture.png("Box", size: CGSize(width: 60, height: 90), hue: 0.3)
        let asked = LineLog()
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: { url in asked.add(url.absoluteString); return (box, 200) })
        let game = ubisoftGame(art: "https://cdn.ubi.test/box.jpg")
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        #expect(asked.all == ["https://cdn.ubi.test/box.jpg"])
        #expect(file.path.hasPrefix(work.appending(path: "covers/store/ubisoft").path))
    }

    @Test("Ubisoft cover: a wide box art is refused and the compat cover is used instead")
    func ubisoftCoverCompat() async throws {
        let work = try scratchDirectory("ubi-cover-compat")
        defer { try? FileManager.default.removeItem(at: work) }
        let wide = try SteamFixture.png("Wide", size: CGSize(width: 90, height: 60), hue: 0.5)
        let portrait = try SteamFixture.png("Steam", size: CGSize(width: 60, height: 90), hue: 0.7)
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: { url in
            url.absoluteString.contains("cdn.ubi.test") ? (wide, 200) : (portrait, 200)
        })
        let game = ubisoftGame(art: "https://cdn.ubi.test/box.jpg", compat: 359550)
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        // The compat AppID's own cover file — same name Steam games get
        #expect(file == work.appending(path: "covers/359550/library_600x900.jpg"))
        // The refused wide image left nothing in the store slot
        #expect(covers.local(for: game, kind: .cover, override: nil) == nil)
    }

    @Test("Ubisoft cover: with no portrait anywhere the tile is the last resort, kept as-is")
    func ubisoftCoverTile() async throws {
        let work = try scratchDirectory("ubi-cover-tile")
        defer { try? FileManager.default.removeItem(at: work) }
        let tile = try SteamFixture.png("Tile", size: CGSize(width: 140, height: 79), hue: 0.9)
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: { _ in (tile, 200) })
        let game = ubisoftGame(art: nil)
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        // The wide tile is kept: last resort serves it, and the local fast path stops re-asking
        #expect(covers.local(for: game, kind: .cover, override: nil) == .image(file))
    }

    // PCGamingWiki's public API answers three things: the page's wikitext (|cover =
    // names the jacket file), a title search for renamed pages, and the file's own URL.
    private func wikiFetch(jacket: Data, parses: MutexBox<Int>, asked: LineLog,
                           missingFirst: Bool = false) -> CoverStore.Fetch {
        { url in
            let s = url.absoluteString
            asked.add(s)
            if s.contains("action=parse") {
                parses.value += 1
                if missingFirst && parses.value == 1 {
                    return (Data(#"{"error":{"code":"missingtitle","info":"No page"}}"#.utf8), 200)
                }
                return (Data(#"{"parse":{"wikitext":{"*":"{{Infobox game\n|cover = Fixture_cover.jpg\n}}"}}}"#.utf8), 200)
            }
            if s.contains("list=search") {
                return (Data(#"{"query":{"search":[{"title":"Fixture Ubi (2020)"}]}}"#.utf8), 200)
            }
            if s.contains("imageinfo") {
                return (Data(#"{"query":{"pages":{"1":{"imageinfo":[{"url":"https://images.pcgamingwiki.com/f/f0/Fixture_cover.jpg"}]}}}}"#.utf8), 200)
            }
            return s.contains("images.pcgamingwiki.com") || s.contains("backgroundTileImageId") ? (jacket, 200) : (Data(), 404)
        }
    }

    @Test("Ubisoft cover: PCGamingWiki's jacket serves when launchers and Steam have none")
    func ubisoftCoverWiki() async throws {
        let work = try scratchDirectory("ubi-cover-wiki")
        defer { try? FileManager.default.removeItem(at: work) }
        let jacket = try SteamFixture.png("Wiki", size: CGSize(width: 60, height: 90), hue: 0.1)
        let asked = LineLog(), parses = MutexBox(0)
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: wikiFetch(jacket: jacket, parses: parses, asked: asked))
        let game = ubisoftGame(art: nil)
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        #expect(file.path.hasPrefix(work.appending(path: "covers/store/ubisoft").path))
        #expect(covers.local(for: game, kind: .cover, override: nil) == .image(file))
        // One page ask, one file ask, one image — and the tile was never wanted
        #expect(asked.all.count == 3)
        #expect(!asked.all.contains { $0.contains("backgroundTileImageId") })
    }

    @Test("Ubisoft cover: the wiki's own search lands the jacket of a renamed page")
    func ubisoftCoverWikiSearch() async throws {
        let work = try scratchDirectory("ubi-cover-wikisearch")
        defer { try? FileManager.default.removeItem(at: work) }
        let jacket = try SteamFixture.png("Wiki", size: CGSize(width: 60, height: 90), hue: 0.1)
        let asked = LineLog(), parses = MutexBox(0)
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: wikiFetch(jacket: jacket, parses: parses, asked: asked, missingFirst: true))
        let game = ubisoftGame(art: nil)  // named "Fixture Ubi" — the wiki page is "Fixture Ubi (2020)"
        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        #expect(parses.value == 2)  // the exact page missed, the searched one named the cover
        #expect(file.path.hasPrefix(work.appending(path: "covers/store/ubisoft").path))
    }

    @Test("Ubisoft cover: a wiki miss falls to the tile and is not asked again for an hour")
    func ubisoftCoverWikiMiss() async throws {
        let work = try scratchDirectory("ubi-cover-wikimiss")
        defer { try? FileManager.default.removeItem(at: work) }
        let tile = try SteamFixture.png("Tile", size: CGSize(width: 140, height: 79), hue: 0.9)
        let asked = LineLog(), parses = MutexBox(0)
        var fetch = wikiFetch(jacket: tile, parses: parses, asked: asked, missingFirst: true)
        let inner = fetch
        fetch = { url in   // the search names nothing the game name is part of
            url.absoluteString.contains("list=search")
                ? (Data(#"{"query":{"search":[{"title":"Something Else Entirely"}]}}"#.utf8), 200)
                : try await inner(url)
        }
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: fetch)
        let game = ubisoftGame(art: nil)
        guard case .image = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("no cover"); return
        }
        let calls = asked.all.count
        _ = await covers.art(for: game, kind: .cover, override: nil)
        // The cached tile serves at once: the hour-old miss means no wiki round-trip
        #expect(asked.all.count == calls)
    }

    @Test("Ubisoft hero: the space's wide art fills the panel's file, apart from the cover")
    func ubisoftHeroFile() async throws {
        let work = try scratchDirectory("ubi-hero")
        defer { try? FileManager.default.removeItem(at: work) }
        let portrait = try SteamFixture.png("Box", size: CGSize(width: 60, height: 90), hue: 0.3)
        let wide = try SteamFixture.png("Bg", size: CGSize(width: 90, height: 60), hue: 0.5)
        let covers = CoverStore(steamCache: work.appending(path: "steam"), cache: work.appending(path: "covers"),
                                fetch: { url in
            url.absoluteString.contains("box.jpg") ? (portrait, 200) : (wide, 200)
        })
        let game = ubisoftGame(art: "https://cdn.ubi.test/box.jpg", header: "https://cdn.ubi.test/bg.jpg")
        guard case .image(let cover) = await covers.art(for: game, kind: .cover, override: nil),
              case .image(let hero) = await covers.art(for: game, kind: .hero, override: nil) else {
            Issue.record("missing art"); return
        }
        #expect(cover != hero)
        #expect(hero.lastPathComponent.contains("hero"))
        #expect(covers.local(for: game, kind: .hero, override: nil) == .image(hero))
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
        #expect(await scene.waitForJobs())
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
        let activity = ActivityCenter(installs: InstallCenter(notifier: RecordingNotifier()), control: RecordingControl(),
                                      notifier: RecordingActivityNotifier())
        activity.storeSource = { [scene] in scene.center.activity }
        activity.stopStore = { [scene] in scene.center.stop($0) }
        scene.center.install(try #require(scene.model.game("epic:Fennec")))
        #expect(await scene.waitUntil { (scene.center.activity?.fraction ?? 0) > 0 })
        let shown = try #require(scene.center.activity)
        #expect(activity.slot == .store(shown))
        #expect(activity.menuSections.map(\.kind) == [.store])
        for dark in [false, true] {
            await windowSnapshot(LibrarySidebar(model: scene.model).activitySlot(activity, library: scene.model),
                                 named: "store-activity", size: CGSize(width: 260, height: 600), dark: dark)
        }
        // Stop on the card cancels the running job, and the game is left uninstalled
        activity.stopStore(shown)
        #expect(await scene.waitForJobs())
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
