import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam's text files")
struct VDFTests {

    @Test("Nested maps, escapes, comments and keys in any case")
    func parses() throws {
        let vdf = try VDF.parse("""
        // written by Steam
        "Root"
        {
            "Name"      "Baldur\\"s \\\\Gate"
            "Apps" { "730" { "LastPlayed" "1700000000" } }
            bare value
        }
        """)
        #expect(vdf["root"]?["name"]?.string == "Baldur\"s \\Gate")
        #expect(vdf[path: "ROOT", "apps", "730", "lastplayed"]?.int == 1_700_000_000)
        #expect(vdf["Root"]?["bare"]?.string == "value")
    }

    @Test("A file cut short is refused, not read in part")
    func truncated() {
        #expect(throws: VDF.Malformed.self) { try VDF.parse("\"AppState\" { \"appid\" \"730\"") }
        #expect(throws: VDF.Malformed.self) { try VDF.parse("\"a\" \"b\" }") }
    }
}

@Suite("Steam library import")
struct SteamImportTests {

    @Test("Steam's files give the account, the installed games on every library, play data and collections")
    func localFiles() throws {
        let fixture = try SteamFixture("files")
        defer { fixture.remove() }
        let files = SteamLocalFiles(userData: fixture.steam)

        let account = try #require(files.account())
        #expect(account == SteamAccount(steamID: SteamFixture.steamID, accountName: "player42", personaName: "Player 42"))
        #expect(account.accountID == SteamFixture.accountID)

        #expect(files.libraries().map(\.lastPathComponent) == ["Steam", "SteamLibrary"])
        let installed = files.installed()
        // God of War is still downloading and Steam's redistributables are not a game
        #expect(installed.map(\.name) == ["Counter-Strike 2", "Hollow Knight", "Baldur’s Gate 3", "Cyberpunk 2077",
                                          "Red Dead Redemption 2", "Elden Ring"])
        #expect(files.installFolder(appID: 730)?.lastPathComponent == "Counter-Strike 2")

        let play = files.playData(account)
        #expect(play[1_245_620]?.playtimeMinutes == 954)
        #expect(play[1_172_470] == nil)

        // Deleted collections and Steam's own Favorites are left out; removed games are applied
        #expect(files.collections(account) == [SteamCollection(id: "uc-souls", name: "Souls", apps: [1_245_620, 1_174_180])])
    }

    @Test("Import from Steam: the export lists every owned game, and the toolbar names the count and the account")
    @MainActor
    func importFromSteam() async throws {
        let fixture = try SteamFixture("import")
        defer { fixture.remove() }
        try fixture.writeExport()
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, running: true, defaults: scratch)
        await model.load()

        #expect(model.steam.presence == .running)
        #expect(model.steam.games.count == SteamFixture.apps.count)
        #expect(model.steam.games.filter(\.installed).count == 6)
        model.selection = .source(.steam)
        #expect(model.title == "Steam")
        #expect(model.subtitle == "8 games. Signed in as player42")
        #expect(model.game("steam:1245620")?.collections == ["Souls"])
    }

    @Test("Import from Steam: a new export shows on the next watcher tick")
    @MainActor
    func newExportOnTick() async throws {
        let fixture = try SteamFixture("watch")
        defer { fixture.remove() }
        let scratch = ScratchDefaults()
        let model = libraryModel(fixture, running: true, defaults: scratch)
        await model.load()
        // Before any export, only the installed games are known
        #expect(model.steam.games.count == 6)

        var stamp = model.importer.exportStamp()
        var running = model.importer.isRunning()
        try fixture.writeExport()
        await model.watchTick(tick: 1, stamp: &stamp, running: &running)
        #expect(model.steam.games.count == 8)
    }

    @Test("Steam closed: the cached games show, installed status from Steam's manifests")
    @MainActor
    func steamClosed() async throws {
        let fixture = try SteamFixture("closed")
        defer { fixture.remove() }
        // The last export, written while God of War was installed and Hollow Knight was not
        var exported = Set(SteamFixture.apps.filter(\.installed).map(\.id))
        exported.insert(1_593_500)
        exported.remove(367_520)
        try fixture.writeExport(installed: exported)
        let model = libraryModel(fixture, running: false, defaults: ScratchDefaults())
        await model.load()

        #expect(model.steam.presence == .closed)
        #expect(model.steam.games.count == 8)
        #expect(model.game("steam:1593500")?.installed == false)
        #expect(model.game("steam:367520")?.installed == true)
        #expect(model.game("steam:1172470")?.installed == false)
        model.selection = .source(.steam)
        #expect(model.subtitle == "8 games. Signed in as player42")
    }

    @Test("Running, the export says what is installed")
    func runningUsesTheExport() throws {
        let fixture = try SteamFixture("running")
        defer { fixture.remove() }
        try fixture.writeExport(installed: [1_593_500])
        let result = fixture.importer(running: true).load()
        #expect(result.games.filter(\.installed).map(\.name) == ["God of War"])
    }

    @Test("Without any export, the installed games and their play data still show")
    func noExport() throws {
        let fixture = try SteamFixture("no-export")
        defer { fixture.remove() }
        let result = fixture.importer(running: false).load()
        #expect(result.exported == nil)
        #expect(result.games.count == 6)
        #expect(result.games.allSatisfy { $0.installed })
        let elden = try #require(result.games.first { $0.steamAppID == 1_245_620 })
        #expect(elden.playtimeMinutes == 954)
        #expect(elden.collections == ["Souls"])
        #expect(elden.status(now: fixture.now) == "Played yesterday")
    }

    @Test("An export from another account on this Mac is not used")
    func otherAccount() throws {
        let fixture = try SteamFixture("other")
        defer { fixture.remove() }
        try fixture.writeExport(steamID: "76561197960265999")
        #expect(fixture.importer(running: true).load().games.count == 6)
    }

    @Test("A damaged export is ignored")
    func damagedExport() throws {
        let fixture = try SteamFixture("damaged")
        defer { fixture.remove() }
        try Data("{\"version\":1,\"apps\":[".utf8).write(to: fixture.export)
        #expect(fixture.importer(running: true).load().games.count == 6)
    }

    @Test("Steam not installed: nothing is read")
    func notInstalled() throws {
        let fixture = try SteamFixture("missing")
        defer { fixture.remove() }
        let result = fixture.importer(installed: false, running: false).load()
        #expect(result.presence == .notInstalled)
        #expect(result.games.isEmpty)
    }
}
