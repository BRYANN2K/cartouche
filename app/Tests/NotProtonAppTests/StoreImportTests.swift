import Foundation
import Testing

@testable import NotProtonApp

// Folders another launcher installed: the Epic launcher's .egstore, GOG Galaxy's
// goggame info, the Amazon Games app's fuel.json. Only games on the account import.
@Suite("Store imports", .serialized)
@MainActor
struct StoreImportTests {

    private func folder(_ scene: StoreScene, _ name: String, files: [String: String]) throws -> URL {
        let root = scene.work.appending(path: "Other Launcher/\(name)", directoryHint: .isDirectory)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Epic: a folder with the launcher's .egstore manifest is registered with legendary; uninstalling leaves its files")
    func epic() async throws {
        let scene = try await StoreScene("import-epic")
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let dir = try folder(scene, "SampleFreeGame", files: [
            ".egstore/7A1B.mancpn": #"{"FormatVersion": 0, "AppName": "Fennec", "CatalogItemId": "x", "CatalogNamespace": "y"}"#,
            "Binaries/Game.exe": "MZ",
        ])
        scene.center.importFolder(dir, into: .epic)
        await scene.waitForJobs()
        let record = try #require(scene.center.record("epic:Fennec"))
        #expect(record.imported)
        #expect(record.install.path.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(scene.calls("legendary").contains("-y import Fennec \(dir.clientPath) --platform Windows"))
        #expect(scene.model.game("epic:Fennec")?.installed == true)
        await scene.center.uninstall(try #require(scene.model.game("epic:Fennec")))
        #expect(scene.center.record("epic:Fennec") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Binaries/Game.exe").path))
        #expect(!scene.calls("legendary").contains { $0.contains("uninstall") })
    }

    @Test("GOG: a folder with goggame info of a game on the account imports and starts from its play task")
    func gog() async throws {
        let scene = try await StoreScene("import-gog", gogServer: true)
        defer { scene.remove() }
        await scene.center.beginSignIn(.gog)
        await scene.center.finishSignIn(.gog, code: "gog-good-code")
        let dir = try folder(scene, "Sample GOG Game", files: [
            "goggame-1207658924.info": #"{"gameId": "1207658924", "rootGameId": "1207658924", "name": "Sample GOG Game", "playTasks": [{"category": "game", "isPrimary": true, "path": "Sample.exe", "type": "FileTask"}]}"#,
            "goggame-1207658924.id": #"{"buildId": "42"}"#,
            "Sample.exe": "MZ",
        ])
        scene.center.importFolder(dir, into: .gog)
        await scene.waitForJobs()
        let record = try #require(scene.center.record("gog:1207658924"))
        #expect(record.imported && record.install.version == "42")
        let adapter = try #require(scene.center.adapter(.gog))
        let launch = try await adapter.launch(record.id, install: record.install, prefix: record.prefix, offline: true)
        #expect(launch.executable.lastPathComponent == "Sample.exe")
    }

    @Test("Amazon: a folder with fuel.json is matched to the library by its name and registered with nile")
    func amazon() async throws {
        let scene = try await StoreScene("import-amazon")
        defer { scene.remove() }
        await scene.center.beginSignIn(.amazon)
        await scene.center.finishSignIn(.amazon, code: "amazon-good-code")
        let dir = try folder(scene, "Sample Amazon Game", files: [
            "fuel.json": #"{"SchemaVersion": "2", "Main": {"Command": "Game\\Sample.exe"}}"#, "Game/Sample.exe": "MZ",
        ])
        scene.center.importFolder(dir, into: .amazon)
        await scene.waitForJobs()
        #expect(scene.center.record("amazon:amzn1.adg.product.SAMPLE")?.imported == true)
        #expect(scene.calls("nile").contains("import --path \(dir.clientPath) amzn1.adg.product.SAMPLE"))
    }

    @Test("A folder that holds no game of the account is refused, and says so")
    func refused() async throws {
        let scene = try await StoreScene("import-refused", gogServer: true)
        defer { scene.remove() }
        await scene.signIn(.epic, code: "epic-good-code")
        let empty = try folder(scene, "Some Folder", files: ["readme.txt": "hello"])
        scene.center.importFolder(empty, into: .epic)
        await scene.waitForJobs()
        #expect(scene.center.problem == "Cartouche couldn’t tell which game is in “Some Folder”.")
        // A GOG game that is not on this account
        await scene.center.beginSignIn(.gog)
        await scene.center.finishSignIn(.gog, code: "gog-good-code")
        scene.center.problem = nil
        let other = try folder(scene, "Not Mine", files: [
            "goggame-999.info": #"{"gameId": "999", "rootGameId": "999", "playTasks": [{"isPrimary": true, "path": "x.exe"}]}"#,
        ])
        scene.center.importFolder(other, into: .gog)
        await scene.waitForJobs()
        #expect(scene.center.problem == "Cartouche couldn’t tell which game is in “Not Mine”.")
        #expect(scene.center.record("gog:999") == nil)
    }
}
