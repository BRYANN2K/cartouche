import Foundation
import Testing

@testable import NotProtonApp

@Suite("Store game uninstall")
struct StoreUninstallTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "store-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test("A picked folder gets the game in its own subfolder")
    func subfolder() {
        let picked = URL(filePath: "/Users/me/Games", directoryHint: .isDirectory)
        let folder = StoreUninstall.folder(in: picked, title: "Hollow Pines", id: "abc/1")
        #expect(folder.deletingLastPathComponent().standardizedFileURL == picked.standardizedFileURL)
        #expect(folder.lastPathComponent != "Games")
        #expect(!folder.lastPathComponent.contains("/"))
    }

    @Test("Uninstall trashes only game, pfx and logs; the user's other files stay")
    func onlyOwned() throws {
        let root = try scratch(), home = try scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: home) }
        let folder = root.appending(path: "picked")
        try write(folder.appending(path: "game/Game.exe"))
        try write(folder.appending(path: "pfx/system.reg"))
        try write(folder.appending(path: "game.log"))
        try write(folder.appending(path: "My Photos/a.jpg"))
        var trashed: [String] = []
        StoreUninstall.clear(folder, home: home) { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        #expect(Set(trashed) == ["game", "pfx", "game.log"])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "My Photos/a.jpg").path(percentEncoded: false)))
    }

    @Test("A folder left empty goes too")
    func emptyGoes() throws {
        let root = try scratch(), home = try scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: home) }
        let folder = root.appending(path: "hollow-pines-1")
        try write(folder.appending(path: "game/Game.exe"))
        StoreUninstall.clear(folder, home: home) { try FileManager.default.removeItem(at: $0) }
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test("Home, its standard folders and volume roots are never touched")
    func protected() throws {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        for path in ["/Users/me", "/Users/me/", "/Users/me/Documents", "/Users/me/Games", "/Users/me/Desktop", "/Volumes/External", "/", "/Volumes"] {
            #expect(StoreUninstall.isProtected(URL(filePath: path, directoryHint: .isDirectory), home: home), "\(path)")
        }
        for path in ["/Users/me/Games/hollow-pines-1", "/Volumes/External/Games/x-2", "/Users/me/Library/Application Support/Cartouche/stores/epic/x-1"] {
            #expect(!StoreUninstall.isProtected(URL(filePath: path, directoryHint: .isDirectory), home: home), "\(path)")
        }
        var trashed = 0
        StoreUninstall.clear(home, home: home) { _ in trashed += 1 }
        #expect(trashed == 0)
    }

    @Test("The store center no longer deletes a record's folder outright")
    func noRecursiveDelete() throws {
        let source = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/NotProtonApp/Stores/StoreCenter.swift"), encoding: .utf8)
        #expect(!source.contains("removeItem(at: record.folder)"))
        #expect(source.contains("StoreUninstall.clear(record.folder)"))
        #expect(source.contains("destination.map { StoreUninstall.folder(in: $0"))
    }
}
