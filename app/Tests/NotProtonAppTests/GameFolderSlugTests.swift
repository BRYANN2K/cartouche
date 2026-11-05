import Foundation
import Testing

@testable import NotProtonApp

// A game.json on a shared or external games location could name any id; uninstall joins it to a path.
@Suite("Installer game ids")
struct GameFolderSlugTests {

    @Test("an id that is not one plain folder name has no folder")
    func unsafeSlugs() {
        let installs = URL(filePath: "/tmp/installs", directoryHint: .isDirectory)
        for slug in ["", ".", "..", "a/b", "../x", "/"] {
            #expect(GameFolder.of(slug: slug, in: installs) == nil, "\(slug)")
            let game = Game(id: "installer:\(slug)", source: .installer, name: "G", installed: true)
            #expect(GameFolder.of(game, in: installs) == nil, "\(slug)")
        }
        #expect(GameFolder.of(slug: "sample-game", in: installs)?.root.lastPathComponent == "sample-game")
    }

    @Test("a record whose id is not its folder's name is left out, so uninstall never reaches the games location")
    @MainActor
    func forgedRecord() throws {
        let work = try scratchDirectory("forged-game-id")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        func write(_ id: String, in name: String) throws -> GameFolder {
            let folder = GameFolder(root: installs.appending(path: name))
            try FileManager.default.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
            try InstalledGames.save(InstalledGame(
                id: id, name: name, runnerID: "r", prefix: folder.prefix.path(percentEncoded: false),
                exe: folder.prefix.appending(path: "game.exe").path(percentEncoded: false),
                installedAt: Date(), installerFolder: "/x", redistributables: []), in: folder)
            return folder
        }
        for (index, id) in ["", ".", "..", "other-game"].enumerated() {
            let folder = try write(id, in: "forged-\(index)")
            #expect(InstalledGames.record(in: folder) == nil, "\(id)")
        }
        let honest = try write("honest", in: "honest")
        #expect(InstalledGames.record(in: honest)?.id == "honest")
        #expect(InstalledGames.all(in: installs, previous: []).map(\.id) == ["honest"])

        for id in ["", ".."] {
            let game = Game(id: "installer:\(id)", source: .installer, name: "G", installed: true)
            #expect(GameUninstall().plan(for: game, installs: installs) == nil, "\(id)")
        }
    }
}
