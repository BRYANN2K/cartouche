import Foundation
import Testing

@testable import NotProtonApp

@Suite("Restore prefix backups")
struct PrefixBackupRestoreTests {
    private func fixture() throws -> (URL, PrefixBackup) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "restore-test-\(UUID().uuidString)")
        let prefix = WinePrefix(appID: "480", name: "Test game", library: SteamLibrary(root: dir), lastUsed: nil)
        let backup = prefix.root.appending(path: "pfx.previous-20260101-120000")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.pfx, withIntermediateDirectories: true)
        try Data("old save".utf8).write(to: backup.appending(path: "user.reg"))
        try Data("current save".utf8).write(to: prefix.pfx.appending(path: "user.reg"))
        try Data("wrong-build\n".utf8).write(to: prefix.root.appending(path: PrefixTools.buildRecordName))
        return (dir, PrefixBackup(prefix: prefix, url: backup, taken: nil, bytes: 0))
    }

    private func content(_ url: URL) throws -> String {
        try String(contentsOf: url.appending(path: "user.reg"), encoding: .utf8)
    }

    @Test("Restoring preserves both saves and removes stale build attribution")
    func preservesBoth() throws {
        let (dir, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parked = try #require(try PrefixStore.restoreBackup(backup, serverRoot: dir.appending(path: "servers")))
        #expect(try content(backup.prefix.pfx) == "old save")
        #expect(try content(backup.url) == "old save")
        #expect(try content(parked) == "current save")
        #expect(PrefixTools.buildRecord(of: backup.prefix) == nil)
    }

    @Test("Failed promotion rolls back the prefix and its build record")
    func rollsBack() throws {
        let (dir, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            try PrefixStore.restoreBackup(backup, serverRoot: dir.appending(path: "servers")) { from, to in
                if from.lastPathComponent.hasPrefix(".pfx.restore-") { throw Refused() }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }
        #expect(try content(backup.prefix.pfx) == "current save")
        #expect(try content(backup.url) == "old save")
        #expect(PrefixTools.buildRecord(of: backup.prefix)?.build == "wrong-build")
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.prefix.root.path()).allSatisfy {
            !$0.hasPrefix(".pfx.restore-") && !$0.hasPrefix(".build.restore-")
        })
    }

    @Test("Restore refuses a prefix held by a launch")
    func refusesBusyPrefix() throws {
        let (dir, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let servers = dir.appending(path: "servers")
        let claim = try #require(PrefixStore.claim(backup.prefix, root: servers))
        defer { claim.release() }
        #expect(throws: StepFailure.self) { try PrefixStore.restoreBackup(backup, serverRoot: servers) }
        #expect(try content(backup.prefix.pfx) == "current save")
    }

    @Test("An unrelated directory or symlink cannot be restored")
    func refusesEscapes() throws {
        let (dir, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unrelated = dir.appending(path: "pfx.previous-unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let outside = PrefixBackup(prefix: backup.prefix, url: unrelated, taken: nil, bytes: 0)
        #expect(throws: StepFailure.self) { try PrefixStore.restoreBackup(outside) }
        let link = backup.prefix.root.appending(path: "pfx.previous-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let linked = PrefixBackup(prefix: backup.prefix, url: link, taken: nil, bytes: 0)
        #expect(throws: StepFailure.self) { try PrefixStore.restoreBackup(linked) }
        #expect(try content(backup.prefix.pfx) == "current save")
    }

    @Test("A backup can recover a missing current prefix")
    func recoversMissingPrefix() throws {
        let (dir, backup) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: backup.prefix.pfx)
        #expect(try PrefixStore.restoreBackup(backup, serverRoot: dir.appending(path: "servers")) == nil)
        #expect(try content(backup.prefix.pfx) == "old save")
        #expect(try content(backup.url) == "old save")
    }
}
