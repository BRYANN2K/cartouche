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

    @Test("The watcher's probes run off the main actor and a presence change lands on it")
    @MainActor
    func watchProbesOffMain() async throws {
        let fixture = try SteamFixture("watch-offmain")
        defer { fixture.remove() }
        let running = Box(false)
        let probed = Box(0)
        let onMain = Box(false)
        var importer = fixture.importer(installed: true, running: false)
        importer.isRunning = {
            probed.value += 1
            onMain.value = onMain.value || Thread.isMainThread
            return running.value
        }
        let model = LibraryModel(store: LibraryStore(folder: fixture.support), importer: importer,
                                 defaults: ScratchDefaults().defaults)
        await model.load()
        #expect(model.steam.presence == .closed)
        #expect(probed.value > 0)

        model.watch(every: .milliseconds(50))
        // Once the baseline has read, flipping running is seen on a running-check tick.
        let baseline = probed.value
        #expect(await waitFor { probed.value > baseline })
        running.value = true
        #expect(await waitFor { model.steam.presence == .running })
        #expect(!onMain.value)
    }

    @Test("Steam closed: the cached games show, installed status from Steam's manifests")
    @MainActor
    func steamClosed() async throws {
        let fixture = try SteamFixture("closed")
        defer { fixture.remove() }
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
        #expect(model.subtitle == "8 games. Signed in as player42. Steam is closed. Some details may be out of date.")
    }

    @Test("Running, the export says what is installed")
    func runningUsesTheExport() throws {
        let fixture = try SteamFixture("running")
        defer { fixture.remove() }
        try fixture.writeExport(installed: [1_593_500])
        let result = fixture.importer(running: true).load()
        #expect(result.games.filter(\.installed).map(\.name) == ["God of War"])
    }

    @Test("Without any export, only the installed manifests show; localconfig is play data, not ownership")
    func noExport() throws {
        let fixture = try SteamFixture("no-export")
        defer { fixture.remove() }
        let now = Int(fixture.now.timeIntervalSince1970)
        try fixture.writeLocalConfig([
            (id: 1_245_620, lastPlayed: now - 86400, playtime: 954),
            (id: 1_172_470, lastPlayed: now - 2 * 86400, playtime: 12),
            (id: 999_999, lastPlayed: now - 86400, playtime: 1),
        ])
        let result = fixture.importer(running: false).load()

        // Apex and the unknown app are in localconfig yet stay unlisted
        #expect(result.exported == nil)
        #expect(result.games.count == 6)
        #expect(result.games.allSatisfy { $0.installed })
        let elden = try #require(result.games.first { $0.steamAppID == 1_245_620 })
        #expect(elden.playtimeMinutes == 954)
        #expect(elden.collections == ["Souls"])
        #expect(elden.status(now: fixture.now) == "Played yesterday")
    }

    @Test("The account's folder is the low 32 bits of its SteamID64")
    func accountFolder() {
        #expect(SteamAccount(steamID: "76561198000000042", accountName: "a", personaName: nil).accountID == SteamFixture.accountID)
        #expect(SteamAccount(steamID: "76561197960265999", accountName: "b", personaName: nil).accountID == "271")
        #expect(SteamAccount(steamID: "not-a-steamid", accountName: "c", personaName: nil).accountID == nil)
    }

    @Test("An export is the whole owned list: localconfig adds nothing to it")
    func exportIsTheOwnedList() throws {
        let fixture = try SteamFixture("merge")
        defer { fixture.remove() }
        let now = Int(fixture.now.timeIntervalSince1970)
        try fixture.writeLocalConfig([
            (id: 1_245_620, lastPlayed: now - 86400, playtime: 954),
            (id: 400, lastPlayed: now - 3 * 86400, playtime: 20),
        ])
        try fixture.writeExport()
        let result = fixture.importer(running: false).load()

        // The export's 8; Portal, only in localconfig, is not ownership data
        #expect(result.games.count == 8)
        #expect(result.games.filter { $0.steamAppID == 1_245_620 }.count == 1)
        #expect(!result.games.contains { $0.steamAppID == 400 })
        #expect(result.exported != nil)
    }

    @Test("Closed, an export older than Steam's files is still the library")
    func staleExport() throws {
        let fixture = try SteamFixture("stale")
        defer { fixture.remove() }
        let now = Int(fixture.now.timeIntervalSince1970)
        try fixture.writeExport()
        try fixture.writeLocalConfig([(id: 1_172_470, lastPlayed: now - 86400, playtime: 40)])
        // Steam touched localconfig after the export was written: the export is stale and still speaks
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: fixture.localConfig.path(percentEncoded: false))
        let result = fixture.importer(running: false).load()

        // All 8 from the export; localconfig's play data still applies to listed games
        #expect(result.exported != nil)
        #expect(result.games.count == 8)
        #expect(result.games.contains { $0.steamAppID == 1_593_500 })
        #expect(result.games.first { $0.steamAppID == 1_172_470 }?.playtimeMinutes == 40)
    }

    @Test("Nothing owned and nothing installed leaves the Steam page empty")
    @MainActor
    func emptyLibrary() async throws {
        let fixture = try SteamFixture("empty")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.steam.appending(path: "steamapps"))
        try FileManager.default.removeItem(at: fixture.external)
        try fixture.writeLocalConfig([])
        let model = libraryModel(fixture, running: false, defaults: ScratchDefaults())
        await model.load()

        #expect(model.steam.presence == .closed)
        #expect(model.steam.games.isEmpty)
        model.selection = .source(.steam)
        #expect(model.screen == .emptySource(.steam))
        #expect(model.subtitle == "0 games. Signed in as player42")
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
