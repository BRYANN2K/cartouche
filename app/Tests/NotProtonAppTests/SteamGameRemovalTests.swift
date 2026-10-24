import CartoucheIdentity
import Foundation
import Testing
@testable import NotProtonApp

@Suite("Steam uninstall and install lifecycle")
struct SteamGameRemovalTests {
    @Test("Confirmed removal deletes only that game's prefix; cancelled uninstall preserves it")
    func prefixCleanup() async throws {
        let fixture = try SteamFixture("remove-prefix")
        defer { fixture.remove() }
        let files = SteamLocalFiles(userData: fixture.steam)
        let own = fixture.steam.appending(path: "steamapps/compatdata/1245620/pfx")
        let other = fixture.steam.appending(path: "steamapps/compatdata/730/pfx")
        for dir in [own, other] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("save".utf8).write(to: dir.appending(path: "save.dat"))
        }
        let plan = try #require(SteamGameRemoval.plan(appID: 1245620, files: files))
        #expect(try !SteamGameRemoval.removePrefixes(plan))
        #expect(FileManager.default.fileExists(atPath: own.path))
        try FileManager.default.removeItem(at: fixture.steam.appending(path: "steamapps/appmanifest_1245620.acf"))
        #expect(try await SteamGameRemoval.finish(plan, polls: 3, interval: .milliseconds(1)))
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "save.dat").path))
    }

    @Test("Disconnecting a Steam library does not count as uninstalling its games")
    func disconnectedLibrary() throws {
        let fixture = try SteamFixture("remove-disconnected")
        defer { fixture.remove() }
        let plan = try #require(SteamGameRemoval.plan(appID: 1245620, files: SteamLocalFiles(userData: fixture.steam)))
        try FileManager.default.moveItem(at: fixture.steam, to: fixture.root.appending(path: "Disconnected"))
        #expect(!SteamGameRemoval.isUninstalled(plan))
        #expect(try !SteamGameRemoval.removePrefixes(plan))
    }

    @Test("A symlink cannot redirect prefix deletion outside compatdata")
    func symlink() throws {
        let fixture = try SteamFixture("remove-symlink")
        defer { fixture.remove() }
        let target = fixture.root.appending(path: "Keep/pfx")
        let link = fixture.steam.appending(path: "steamapps/compatdata/1245620")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let plan = try #require(SteamGameRemoval.plan(appID: 1245620, files: SteamLocalFiles(userData: fixture.steam)))
        try FileManager.default.removeItem(at: fixture.steam.appending(path: "steamapps/appmanifest_1245620.acf"))
        #expect(throws: (any Error).self) { try SteamGameRemoval.removePrefixes(plan) }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    @Test("Handing installation to Steam clears its request so uninstall cannot resurrect it")
    func clearTransferredInstall() async throws {
        let fixture = try SteamFixture("install-lifecycle")
        defer { fixture.remove() }
        try fixture.writeExport()
        let model = libraryModel(fixture, running: true, defaults: ScratchDefaults())
        await model.load()
        let game = try #require(model.game("steam:1172470"))
        let center = SteamInstallCenter()
        center.support = fixture.support
        center.integrationVersion = { CARTOUCHE_STEAM_INTEGRATION_VERSION }
        center.install(game, model: model, destination: fixture.steam)
        #expect(center.status?.game.id == game.id)
        center.clear(appID: 730)
        #expect(center.status != nil)
        var snapshot = SteamActivitySnapshot()
        snapshot.installed = [1172470]
        center.reconcile(snapshot)
        #expect(center.status == nil)
        center.reconcile(SteamActivitySnapshot())
        #expect(center.status == nil)
        center.install(game, model: model, destination: fixture.steam)
        snapshot.installed = []
        snapshot.downloads = [DownloadActivity(appID: 1172470, name: game.name, state: .downloading,
                                               bytesDone: 0, bytesTotal: 100)]
        center.reconcile(snapshot)
        #expect(center.status == nil)
    }
    @MainActor
    @Test("An older integration is updated manually before background installation")
    func backgroundRequiresNewIntegration() async throws {
        let fixture = try SteamFixture("background-install-version")
        defer { fixture.remove() }
        try fixture.writeExport()
        let model = libraryModel(fixture, running: true, defaults: ScratchDefaults())
        await model.load()
        let game = try #require(model.game("steam:1172470"))
        let center = SteamInstallCenter()
        center.support = fixture.support
        center.integrationVersion = { "0.1.0-3" }
        center.install(game, model: model, destination: fixture.steam)
        #expect(center.status?.state == "failed")
        #expect(center.status?.message?.contains("Settings > Steam") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.appending(path: "steam-install-command.json").path))
    }

}
