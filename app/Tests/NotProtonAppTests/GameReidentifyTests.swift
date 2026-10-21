import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Records written before the identification pipeline kept a raw folder name.
// The load-time pass names them again: a confident match renames the record
// itself, a weaker answer is offered in the panel, a user-set name stays.
@MainActor
@Suite("Re-identifying installed games")
struct GameReidentifyTests {

    private struct Scene {
        let work: URL
        let installs: URL
        let games: URL
        let folder: GameFolder
        let model: LibraryModel
    }

    // A record whose name is the raw folder the import kept; exe and folder live
    // outside the prefix, as an in-place import leaves them.
    private func scene(_ label: String, name: String, exe: String = "game.exe",
                       userNamed: Bool = false) throws -> Scene {
        let work = try scratchDirectory(label)
        let installs = work.appending(path: "installs")
        let games = work.appending(path: "games")
        let folder = GameFolder(root: installs.appending(path: GameFolder.slug(name)))
        let fm = FileManager.default
        let gameDir = games.appending(path: name)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: gameDir.appending(path: exe))
        var record = InstalledGame(
            id: folder.root.lastPathComponent, name: name, appID: nil, gogID: nil,
            runnerID: "r", graphics: GraphicsBackend.wined3d.rawValue, wineVersion: nil, wineRunnerKind: nil,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: gameDir.appending(path: exe).path(percentEncoded: false),
            installedAt: Date(), installerFolder: gameDir.path(percentEncoded: false),
            redistributables: [], gameFolder: gameDir.path(percentEncoded: false))
        if userNamed { record.userNamed = true }
        try InstalledGames.save(record, in: folder)
        let fixture = try SteamFixture("\(label)-steam")
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = installs
        model.showInstalledGames(InstalledGames.all(in: installs))
        return Scene(work: work, installs: installs, games: games, folder: folder, model: model)
    }

    private func record(_ s: Scene) throws -> InstalledGame {
        try #require(InstalledGames.record(in: s.folder))
    }

    private func lookup(in dir: URL, answering item: SteamLookup.Item?) -> SteamLookup {
        var lookup = SteamLookup()
        lookup.directory = dir
        if let item {
            let data = try! JSONSerialization.data(withJSONObject: [
                "items": [["id": item.appID, "name": item.name, "type": "app", "tiny_image": ""]],
            ])
            lookup.fetch = { _ in (data, 200) }
        } else {
            lookup.fetch = { _ in (Data("{\"items\":[]}".utf8), 200) }
        }
        return lookup
    }

    @Test("A steam_appid.txt the folder carries renames the record and keeps the app ID")
    func confidentMatchRenames() async throws {
        let s = try scene("reid-match", name: "Hollow-Knight-Silksong-GameSite com")
        defer { try? FileManager.default.removeItem(at: s.work) }
        try Data("367520".utf8).write(to: s.games.appending(path: "Hollow-Knight-Silksong-GameSite com/steam_appid.txt"))

        await s.model.reidentifyInstalledGames(
            index: GameIndex([GameIndex.Entry(appID: 367520, name: "Hollow Knight")]),
            lookup: lookup(in: s.work.appending(path: "steam-lookup"), answering: nil),
            allowed: false)

        let record = try record(s)
        #expect(record.name == "Hollow Knight")
        #expect(record.appID == 367520)
        #expect(record.userNamed != true)
        #expect(s.model.nameSuggestions.isEmpty)
        #expect(s.model.game("installer:\(s.folder.root.lastPathComponent)")?.name == "Hollow Knight")
    }

    @Test("A cleaned name nothing matched stays a suggestion, never a rename")
    func weakAnswerIsSuggested() async throws {
        let s = try scene("reid-suggest", name: "Hollow-Knight-Silksong-GameSite com",
                          exe: "Hollow Knight Silksong.exe")
        defer { try? FileManager.default.removeItem(at: s.work) }

        await s.model.reidentifyInstalledGames(
            index: GameIndex([]),
            lookup: lookup(in: s.work.appending(path: "steam-lookup"), answering: nil),
            allowed: false)

        #expect(try record(s).name == "Hollow-Knight-Silksong-GameSite com")
        #expect(s.model.nameSuggestions["installer:\(s.folder.root.lastPathComponent)"] == "Hollow Knight Silksong")
    }

    @Test("A Steam store answer counts as a match only when lookups are allowed")
    func steamAnswerNeedsPermission() async throws {
        let s = try scene("reid-steam", name: "Hollow-Knight-Silksong-GameSite.com")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let steam = lookup(in: s.work.appending(path: "steam-lookup"),
                           answering: SteamLookup.Item(appID: 367520, name: "Hollow Knight Silksong", kind: "app", capsule: nil))

        // The same raw name with lookups off: nothing leaves the Mac.
        await s.model.reidentifyInstalledGames(index: GameIndex([]), lookup: steam, allowed: false)
        #expect(try record(s).name == "Hollow-Knight-Silksong-GameSite.com")

        await s.model.reidentifyInstalledGames(index: GameIndex([]), lookup: steam, allowed: true)
        let record = try record(s)
        #expect(record.name == "Hollow Knight Silksong")
        #expect(record.appID == 367520)
    }

    @Test("A name the user set is left alone, and Rename marks it so")
    func userNamesStay() async throws {
        let s = try scene("reid-user", name: "Hollow-Knight-Silksong-GameSite com",
                          exe: "Hollow Knight Silksong.exe")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let game = try #require(s.model.game("installer:\(s.folder.root.lastPathComponent)"))

        await s.model.reidentifyInstalledGames(
            index: GameIndex([GameIndex.Entry(appID: 367520, name: "Hollow Knight")]),
            lookup: lookup(in: s.work.appending(path: "steam-lookup"), answering: nil),
            allowed: false)
        #expect(s.model.nameSuggestions[game.id] != nil)

        s.model.rename(game, to: "My Knight")
        #expect(try record(s).name == "My Knight")
        #expect(try record(s).userNamed == true)
        #expect(s.model.nameSuggestions[game.id] == nil)
        #expect(s.model.game(game.id)?.name == "My Knight")

        // The pass runs again and never touches the user's name back.
        await s.model.reidentifyInstalledGames(
            index: GameIndex([GameIndex.Entry(appID: 367520, name: "Hollow Knight")]),
            lookup: lookup(in: s.work.appending(path: "steam-lookup"), answering: nil),
            allowed: false)
        #expect(try record(s).name == "My Knight")
        #expect(s.model.nameSuggestions.isEmpty)
    }

    @Test("Rename… is offered for a local game and its record takes the answer")
    func menuRename() async throws {
        let s = try scene("reid-menu", name: "Sample-Game-GameSite com")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let game = try #require(s.model.game("installer:\(s.folder.root.lastPathComponent)"))
        let item = GameMenu.items(for: game, in: s.model).first { $0.action == .rename }
        #expect(item?.title == "Rename…")

        var runner = GameActionRunner(model: s.model, open: { _ in })
        runner.renamePrompt = { _ in "Sample Game" }
        runner.perform(.rename, on: game)
        #expect(try record(s).name == "Sample Game")
        #expect(try record(s).userNamed == true)
    }

    @Test("Folder junk is raw; a real name, even a hyphenated one, is not")
    func rawNames() {
        #expect(GameName.looksRaw("Hollow-Knight-Silksong-GameSite com"))
        #expect(GameName.looksRaw("Game-Install Dir GameSite.com"))
        #expect(GameName.looksRaw("Cool Game v1.2 (GOG)"))
        #expect(!GameName.looksRaw("Half-Life"))
        #expect(!GameName.looksRaw("Baldur’s Gate 3"))
        #expect(!GameName.looksRaw("Hollow Knight: Silksong"))
    }
}
