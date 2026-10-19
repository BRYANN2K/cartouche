import CryptoKit
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Store clients")
struct StoreClientTests {

    @Test("legendary, gogdl, comet and nile are pinned by version, size and SHA-256, on github.com, under licenses that allow it")
    func pins() throws {
        let manifest = try StoreClientManifest.bundled()
        #expect(manifest.problems().isEmpty)
        let pins = Dictionary(uniqueKeysWithValues: manifest.clients.map { ($0.client, $0) })
        #expect(pins[.legendary]?.version == "0.21.1")
        #expect(pins[.gogdl]?.version == "1.3.1")
        #expect(pins[.comet]?.version == "0.3.2")
        #expect(pins[.nile]?.version == "1.2.0")
        #expect(pins[.comet]?.license == "Apache-2.0")
        #expect([pins[.legendary], pins[.gogdl], pins[.nile]].allSatisfy { $0?.license == "GPL-3.0" })
        for pin in manifest.clients {
            #expect(pin.url.absoluteString.hasPrefix(pin.source.absoluteString + "/releases/download/"))
            #expect(pin.file.contains("arm64") || pin.file.contains("aarch64"))
        }
    }

    @Test("A pin on another host, with a bad hash or a closed license is refused")
    func refusesBadPins() throws {
        let good = try StoreClientManifest.bundled()
        var clients = good.clients
        let first = clients[0]
        clients[0] = .init(client: first.client, version: first.version, license: "Proprietary", source: first.source,
                           url: URL(string: "http://example.com/legendary")!, size: first.size, sha256: "ABC")
        let problems = StoreClientManifest(format: 1, revision: 1, clients: clients).problems()
        #expect(problems.contains { $0.contains("is not an https URL on github.com") })
        #expect(problems.contains { $0.contains("is not a SHA-256") })
        #expect(problems.contains { $0.contains("license Proprietary") })
    }

    private func pin(_ bytes: Data, at base: URL) -> StoreClientManifest {
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let pins = StoreClient.allCases.map {
            StoreClientManifest.Pin(client: $0, version: "1.0", license: "GPL-3.0", source: URL(string: "https://github.com/x/\($0.rawValue)")!,
                                    url: base.appending(path: "\($0.rawValue)_macOS_arm64"), size: Int64(bytes.count), sha256: sha)
        }
        return StoreClientManifest(format: 1, revision: 1, clients: pins)
    }

    @Test("The first use downloads the client, checks it against its pin and makes it executable")
    func downloadsOnce() async throws {
        let work = try scratchDirectory("client-download")
        defer { try? FileManager.default.removeItem(at: work) }
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        let bytes = Data("#!/bin/sh\necho legendary 0.21.1\n".utf8)
        server.put("/legendary_macOS_arm64", bytes)
        let files = StoreClientFiles(root: work.appending(path: "clients"), downloads: work.appending(path: "downloads"),
                                     manifest: pin(bytes, at: base))
        #expect(!files.isReady(.legendary))
        let url = try await files.ensure(.legendary)
        #expect(url == work.appending(path: "clients/legendary-1.0/legendary"))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(files.isReady(.legendary))
        // The archive in downloads is gone; a second use asks nothing
        _ = try await files.ensure(.legendary)
        #expect(server.requests.count == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: work.appending(path: "downloads").path))?.isEmpty ?? true)
    }

    @Test("A download that does not match its pin is refused and nothing is kept")
    func refusesMismatch() async throws {
        let work = try scratchDirectory("client-mismatch")
        defer { try? FileManager.default.removeItem(at: work) }
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        server.put("/gogdl_macOS_arm64", Data("tampered".utf8))
        let files = StoreClientFiles(root: work.appending(path: "clients"), downloads: work.appending(path: "downloads"),
                                     manifest: pin(Data("expected".utf8), at: base))
        await #expect(throws: StepFailure.self) { try await files.ensure(.gogdl) }
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "clients/gogdl-1.0/gogdl").path))
    }

    @Test("A client changed on disk is no longer ready and is fetched again")
    func changedClient() async throws {
        let work = try scratchDirectory("client-changed")
        defer { try? FileManager.default.removeItem(at: work) }
        let server = try StoreAPIServer()
        let base = try await server.start()
        defer { server.stop() }
        let bytes = Data("nile 1.2.0".utf8)
        server.put("/nile_macOS_arm64", bytes)
        let files = StoreClientFiles(root: work.appending(path: "clients"), downloads: work.appending(path: "downloads"),
                                     manifest: pin(bytes, at: base))
        let url = try await files.ensure(.nile)
        try Data("nile 1.2.0 with something added".utf8).write(to: url)
        #expect(!files.isReady(.nile))
        _ = try await files.ensure(.nile)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(server.requests.count == 2)
    }

    @Test("A client runs with its own HOME, temporary folder and config, never the app's environment")
    func ownEnvironment() async throws {
        let work = try scratchDirectory("client-env")
        defer { try? FileManager.default.removeItem(at: work) }
        let stub = work.appending(path: "bin/legendary")
        try StoreStubs.install("#!/bin/sh\nenv | sort\necho '[DLManager] INFO: = Progress: 42.00% (1/2)' >&2\n", at: stub)
        var files = StoreClientFiles(root: work, downloads: work)
        files.overrides[.legendary] = stub
        let folders = StoreFolders(root: work.appending(path: "stores"))
        let secrets = folders.secrets(vault: MemoryVault())
        let context = folders.context(.epic, files: files, secrets: secrets)
        let lines = LineLog()
        let output = try await context.run(.legendary, store: .epic, ["status"]) { lines.add($0) }
        let env = Set(output.stdout.split(separator: "\n").map { String($0.split(separator: "=").first ?? "") })
        #expect(env.isSubset(of: ["HOME", "TMPDIR", "PATH", "LANG", "LC_ALL", "LEGENDARY_CONFIG_PATH", "PWD", "SHLVL", "_", "OLDPWD"]))
        #expect(output.stdout.contains("HOME=\(folders.home(.epic).path(percentEncoded: false))"))
        #expect(output.stdout.contains("LEGENDARY_CONFIG_PATH=\(folders.client(.epic).path(percentEncoded: false))"))
        #expect(lines.all.compactMap(ClientProgress.fraction) == [0.42])
    }

    @Test("Progress lines of all three clients are read")
    func progress() {
        #expect(ClientProgress.fraction("[DLManager] INFO: = Progress: 12.50% (1/8), Running for 00:00:01, ETA: 00:00:07") == 0.125)
        #expect(ClientProgress.fraction("[PROGRESS] INFO: = Progress: 75.00 300/400, Running for: 00:00:01, ETA: 00:00:00") == 0.75)
        #expect(ClientProgress.fraction("[DLManager] INFO:  - Downloaded: 1.00 MiB, Written: 1.00 MiB") == nil)
        #expect(ClientLog.lastError("[cli] INFO: Logging in...\n[cli] ERROR: Game is out of date, please update\n") == "Game is out of date, please update")
    }
}

final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
