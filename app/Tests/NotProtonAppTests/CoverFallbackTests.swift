import AppKit
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Installer cover fallback")
@MainActor
struct CoverFallbackTests {

    private func installerGame(_ id: String = "installer:x", name: String = "CarX Street", exe: URL? = nil) -> Game {
        Game(id: id, source: .installer, name: name, installed: true, executable: exe)
    }

    private func writeRecord(_ fixture: SteamFixture, id: String, name: String, appID: Int?) throws -> URL {
        let folder = fixture.root.appending(path: "installs/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try InstalledGames.save(InstalledGame(
            id: id, name: name, appID: appID, runnerID: "r",
            prefix: folder.appending(path: "prefix").path(percentEncoded: false),
            exe: folder.appending(path: "game.exe").path(percentEncoded: false),
            installedAt: Date(), installerFolder: "/src", redistributables: []),
            in: GameFolder(root: folder))
        return folder
    }

    // MARK: Exe-icon placeholder

    @Test("No remote art: the exe's own icon becomes a generated cover, kept in the cache")
    func placeholder() async throws {
        let fixture = try SteamFixture("placeholder")
        defer { fixture.remove() }
        let exe = fixture.root.appending(path: "carx.exe")
        try Data("MZ".utf8).write(to: exe)
        let icon = try #require(NSImage(data: SteamFixture.png("X", size: CGSize(width: 64, height: 64), hue: 0.5)))
        var covers = fixture.covers()
        covers.exeIcon = { _, _ in icon }
        let game = installerGame(exe: exe)

        guard case .image(let file) = await covers.art(for: game, kind: .cover, override: nil) else {
            Issue.record("the exe icon should have become the cover")
            return
        }
        #expect(file.deletingLastPathComponent().lastPathComponent == "placeholders")
        #expect(file.lastPathComponent.hasSuffix("-library_600x900.png"))
        #expect(NSImage(contentsOf: file) != nil)
        // The placeholder then serves straight from the cache
        #expect(covers.local(for: game, kind: .cover, override: nil) == .image(file))

        guard case .image(let hero) = await covers.art(for: game, kind: .hero, override: nil) else {
            Issue.record("the hero gets its own placeholder")
            return
        }
        #expect(hero.lastPathComponent.hasSuffix("-library_hero.png"))
    }

    @Test("An exe without an icon still ends on the drawn cover, and iconmaker is not rerun for a day")
    func noIcon() async throws {
        let fixture = try SteamFixture("noicon")
        defer { fixture.remove() }
        let exe = fixture.root.appending(path: "game.exe")
        try Data("MZ".utf8).write(to: exe)
        let asked = Box(0)
        var covers = fixture.covers()
        covers.exeIcon = { _, _ in asked.value += 1; return nil }
        let game = installerGame(exe: exe)

        #expect(await covers.art(for: game, kind: .cover, override: nil) == .drawn)
        #expect(await covers.art(for: game, kind: .cover, override: nil) == .drawn)
        #expect(asked.value == 1)
    }

    @Test("Only installer games get the exe-icon fallback")
    func scope() async throws {
        let fixture = try SteamFixture("scope")
        defer { fixture.remove() }
        let exe = fixture.root.appending(path: "game.exe")
        try Data("MZ".utf8).write(to: exe)
        var covers = fixture.covers()
        covers.exeIcon = { _, _ in NSImage(data: Data()) }
        // A Steam game with no cached art and no CDN stays drawn even with an exe present
        var steam = Game.steam(9_999_999, name: "No Art", installed: true)
        steam.executable = exe
        #expect(await covers.art(for: steam, kind: .cover, override: nil) == .drawn)
    }

    @Test("The generated cover is stable per game name")
    func hueStable() {
        #expect(PlaceholderCover.hue("CarX Street") == PlaceholderCover.hue("CarX Street"))
        #expect(PlaceholderCover.hue("CarX Street") != PlaceholderCover.hue("Elden Ring"))
    }

    // MARK: App IDs on the install record

    @Test("An installed game with no app ID asks Steam once and keeps the answer on its record")
    func resolveRecord() async throws {
        let fixture = try SteamFixture("resolve")
        defer { fixture.remove() }
        let folder = try writeRecord(fixture, id: "carx-street", name: "CarX Street", appID: nil)
        let asked = Box<[URL]>([])
        var lookup = SteamLookup(directory: fixture.root.appending(path: "lookup"))
        lookup.fetch = { url in
            asked.value.append(url)
            let body = try? JSONSerialization.data(withJSONObject: [
                "total": 1, "items": [["id": 1_118_860, "type": "app", "name": "CarX Street"]],
            ])
            return (body ?? Data(), 200)
        }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = fixture.root.appending(path: "installs")

        await model.resolveInstallerAppIDs(lookup: lookup, allowed: true)
        let saved = try #require(InstalledGames.record(in: GameFolder(root: folder)))
        #expect(saved.appID == 1_118_860)
        #expect(model.game("installer:carx-street")?.steamAppID == 1_118_860)
        #expect(asked.value.count == 1)

        // A restart sees the saved ID and asks nothing
        let restarted = libraryModel(fixture, defaults: ScratchDefaults())
        restarted.installsFolder = fixture.root.appending(path: "installs")
        restarted.showInstalledGames(InstalledGames.all(in: restarted.installsFolder))
        #expect(restarted.game("installer:carx-street")?.steamAppID == 1_118_860)
        await restarted.resolveInstallerAppIDs(lookup: lookup, allowed: true)
        #expect(asked.value.count == 1)
    }

    @Test("With online lookups off, no name is sent to Steam")
    func resolveOff() async throws {
        let fixture = try SteamFixture("resolve-off")
        defer { fixture.remove() }
        let folder = try writeRecord(fixture, id: "carx-street", name: "CarX Street", appID: nil)
        let asked = Box<[URL]>([])
        var lookup = SteamLookup(directory: fixture.root.appending(path: "lookup"))
        lookup.fetch = { url in asked.value.append(url); return (Data(), 500) }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = fixture.root.appending(path: "installs")

        await model.resolveInstallerAppIDs(lookup: lookup, allowed: false)
        #expect(asked.value.isEmpty)
        #expect(InstalledGames.record(in: GameFolder(root: folder))?.appID == nil)
    }

    // MARK: Manual override

    @Test("Change Cover offers Search Steam and an image picker")
    func menu() async throws {
        let fixture = try SteamFixture("cover-menu")
        defer { fixture.remove() }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        let game = installerGame()
        let items = GameMenu.items(for: game, in: model)
        let change = try #require(items.first { $0.title == "Change Cover…" })
        #expect(change.action == nil)
        #expect(change.children.map(\.action) == [.searchCover, .changeCover])
        #expect(change.children.map(\.title) == ["Search Steam…", "Choose an Image…"])

        // Search Steam opens the sheet through the injected closure
        let picked = Box<Game?>(nil)
        let runner = GameActionRunner(model: model, searchCover: { picked.value = $0 })
        runner.perform(.searchCover, on: game)
        #expect(picked.value?.id == game.id)

        // The image choice still stores a per-game cover
        let image = fixture.root.appending(path: "chosen.png")
        try SteamFixture.png("Mine", size: CGSize(width: 60, height: 90), hue: 0.3).write(to: image)
        let chooser = GameActionRunner(model: model, chooseImage: { image })
        chooser.perform(.changeCover, on: game)
        #expect(model.coverOverride(for: game.id) != nil)
    }

    @Test("Picking a Steam result stores the downloaded cover and fills a missing app ID")
    func steamPick() async throws {
        let fixture = try SteamFixture("steam-pick")
        defer { fixture.remove() }
        let folder = try writeRecord(fixture, id: "carx-street", name: "CarX Street", appID: nil)
        let art = try SteamFixture.png("CarX", size: CGSize(width: 60, height: 90), hue: 0.9)
        let covers = fixture.covers { _ in (art, 200) }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = fixture.root.appending(path: "installs")
        model.showInstalledGames(InstalledGames.all(in: model.installsFolder))
        let game = try #require(model.game("installer:carx-street"))

        let item = SteamLookup.Item(appID: 1_118_860, name: "CarX Street", kind: "app", capsule: nil)
        #expect(await model.useSteamCover(item, for: game, covers: covers))
        let override = try #require(model.coverOverride(for: game.id))
        #expect(covers.local(for: game, kind: .cover, override: override) == .image(override))
        #expect(InstalledGames.record(in: GameFolder(root: folder))?.appID == 1_118_860)
        #expect(model.game("installer:carx-street")?.steamAppID == 1_118_860)
    }

    @Test("A known app ID is kept when a Steam cover is picked")
    func keepsAppID() async throws {
        let fixture = try SteamFixture("keep-appid")
        defer { fixture.remove() }
        let folder = try writeRecord(fixture, id: "carx-street", name: "CarX Street", appID: 42)
        let art = try SteamFixture.png("CarX", size: CGSize(width: 60, height: 90), hue: 0.9)
        let covers = fixture.covers { _ in (art, 200) }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = fixture.root.appending(path: "installs")
        model.showInstalledGames(InstalledGames.all(in: model.installsFolder))
        let game = try #require(model.game("installer:carx-street"))

        let item = SteamLookup.Item(appID: 1_118_860, name: "CarX Street", kind: "app", capsule: nil)
        #expect(await model.useSteamCover(item, for: game, covers: covers))
        #expect(InstalledGames.record(in: GameFolder(root: folder))?.appID == 42)
    }
}
