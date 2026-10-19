import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Watched game folders", .serialized)
@MainActor
struct GameFolderTests {

    // Four Game Boy homebrew cartridges the recorded database rows know
    private func gameBoyFolder(_ scene: ConsoleScene) throws -> URL {
        let folder = scene.work.appending(path: "Games/Consoles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for cart in ConsoleFixtures.gameBoy {
            try ConsoleFixtures.homebrewGB(title: cart.title, fill: cart.fill).write(to: folder.appending(path: cart.file))
        }
        return folder
    }

    @Test("Games already found are suggested: 4 Game Boy games in the folder, Game Boy not added, its tile says \"4 games found\"")
    func foundGamesAreSuggested() async throws {
        let scene = try ConsoleScene("found")
        defer { scene.remove(); scene.center.stopWatching() }
        let folder = try gameBoyFolder(scene)
        await scene.center.reload()
        await scene.center.addFolder(folder)

        #expect(!scene.center.isAdded("gb"))
        #expect(scene.center.found == ["gb": 4])
        #expect(scene.library.consoleGames.isEmpty)
        let texts = try await renderedTexts(AddConsolesSheet(center: scene.center), size: CGSize(width: 660, height: 560),
                                            named: "add-consoles-found")
        _ = try await renderedTexts(AddConsolesSheet(center: scene.center), size: CGSize(width: 660, height: 560),
                                    named: "add-consoles-found", dark: true)
        #expect(seen(texts, "4 games found"))
        print("evidence: folder holds \(ConsoleFixtures.gameBoy.count) Game Boy files, found \(scene.center.found), tile reads '4 games found': \(seen(texts, "4 games found"))")

        // Settings > Library shows the folder and its count
        let section = Form { GameFoldersSection(folders: scene.folders) }.formStyle(.grouped).environment(scene.center)
        let pane = try await renderedTexts(section, size: CGSize(width: 640, height: 300), named: "settings-game-folders")
        _ = try await renderedTexts(section, size: CGSize(width: 640, height: 300), named: "settings-game-folders", dark: true)
        #expect(seen(pane, "Watched. 4 games found"))
        #expect(seen(pane, "Add Folder"))

        // Adding Game Boy brings the four in
        await scene.center.add(["gb"])
        #expect(scene.library.games(in: .source(.console("gb"))).map(\.name).sorted()
            == ["Cartouche Maze", "Cartouche Puzzle", "Cartouche Quest", "Cartouche Race"])
        #expect(scene.center.found.isEmpty)
    }

    @Test("Watched folder: a recognized game copied in appears in its console within 10 seconds, no sheet opened")
    func copiedGameAppears() async throws {
        let scene = try ConsoleScene("watch")
        defer { scene.remove(); scene.center.stopWatching() }
        await scene.center.add(["gb"])
        let folder = scene.work.appending(path: "Watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scene.folders.add(folder)
        await scene.center.startWatching()
        #expect(scene.library.consoleGames.isEmpty)

        // The user's file, copied in from elsewhere while Cartouche runs
        let outside = scene.work.appending(path: "Downloads/quest.gb")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConsoleFixtures.homebrewGB(title: "CARTOUCHE QUEST").write(to: outside)
        let copied = ContinuousClock.now
        try FileManager.default.copyItem(at: outside, to: folder.appending(path: "quest.gb"))

        var took: Duration?
        while ContinuousClock.now - copied < .seconds(12) {
            if scene.library.games(in: .source(.console("gb"))).contains(where: { $0.name == "Cartouche Quest" }) {
                took = ContinuousClock.now - copied
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = try #require(took, "the game never appeared")
        #expect(after < .seconds(10))
        #expect(scene.library.addGames == nil)
        #expect(!scene.library.showAddConsoles)
        print("evidence: quest.gb copied into the watched folder, in Game Boy as 'Cartouche Quest' after \(after)")

        // A file the database does not know stays out
        try Data(repeating: 9, count: 2048).write(to: folder.appending(path: "unknown.gb"))
        try await Task.sleep(for: .seconds(3))
        #expect(scene.library.games(in: .source(.console("gb"))).count == 1)
    }

    @Test("Folders are kept, and turning automatic adding off leaves new games out")
    func choicesAreKept() async throws {
        let scene = try ConsoleScene("choices")
        defer { scene.remove(); scene.center.stopWatching() }
        let folder = try gameBoyFolder(scene)
        await scene.center.add(["gb"])
        await scene.center.setAddAutomatically(false)
        await scene.center.addFolder(folder)
        #expect(scene.library.consoleGames.isEmpty)
        #expect(scene.folders.paths == [folder.plainPath])
        #expect(!WatchedFolders.load(scene.paths).addAutomatically)
        await scene.center.setAddAutomatically(true)
        #expect(scene.library.consoleGames.count == 4)
        await scene.center.removeFolder(scene.folders.paths[0])
        #expect(scene.folders.paths.isEmpty)
        // Removing a folder never touches its files
        #expect(ConsoleFixtures.gameBoy.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0.file).path) })
        #expect(WatchedFolderState.text("/Volumes/Not Here/ROMs", count: 0) == "Watched when the disk is connected")
    }
}
