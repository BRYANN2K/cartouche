import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam shortcuts")
struct SteamShortcutsTests {

    private func account(_ userdata: URL, _ id: String, entries: [(String, BinaryVDF)] = []) throws -> URL {
        let dir = userdata.appending(path: "\(id)/config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "shortcuts.vdf")
        try BinaryVDF.serialize([("shortcuts", .map(entries))]).write(to: file)
        return file
    }

    private func shortcuts(_ file: URL) throws -> [(String, BinaryVDF)] {
        let root = try #require(BinaryVDF.parse(try Data(contentsOf: file)))
        guard case .map(let entries) = root.first?.1 else { Issue.record("no shortcuts map"); return [] }
        return entries
    }

    @Test("A second account's unreadable file leaves the first account's file and backup untouched")
    func parseAllBeforeWrite() throws {
        let work = try scratchDirectory("steam-shortcuts-fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let userdata = work.appending(path: "userdata")
        let first = try account(userdata, "111")
        let bad = userdata.appending(path: "222/config")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: bad.appending(path: "shortcuts.vdf"))
        let before = try Data(contentsOf: first)

        let steam = SteamShortcuts(userdata: userdata, steamIsRunning: { false })
        guard case .failed = steam.add(name: "G", launcher: URL(filePath: "/x/launch"), startDir: URL(filePath: "/x")) else {
            Issue.record("expected .failed")
            return
        }
        #expect(try Data(contentsOf: first) == before)
        #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false) + ".cartouche"))
    }

    @Test("A gap in the entry keys never collides, and a .cartouche copy of the old file is kept")
    func keysAndBackup() throws {
        let work = try scratchDirectory("steam-shortcuts-keys")
        defer { try? FileManager.default.removeItem(at: work) }
        let userdata = work.appending(path: "userdata")
        let file = try account(userdata, "111", entries: [
            ("0", BinaryVDF.shortcut(name: "A", exe: "\"/a\"", startDir: URL(filePath: "/a"))),
            ("2", BinaryVDF.shortcut(name: "B", exe: "\"/b\"", startDir: URL(filePath: "/b"))),
        ])
        let before = try Data(contentsOf: file)

        let steam = SteamShortcuts(userdata: userdata, steamIsRunning: { false })
        #expect(steam.add(name: "G", launcher: URL(filePath: "/x/launch"), startDir: URL(filePath: "/x")) == .added)

        let keys = try shortcuts(file).map(\.0)
        #expect(keys == ["0", "2", "3"])
        #expect(try Data(contentsOf: file.appendingPathExtension("cartouche")) == before)
        // Adding again is a no-op: the same exe is already there.
        #expect(steam.add(name: "G", launcher: URL(filePath: "/x/launch"), startDir: URL(filePath: "/x")) == .alreadyThere)
    }
}
