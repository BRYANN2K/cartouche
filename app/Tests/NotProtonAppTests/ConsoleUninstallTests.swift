import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

// Removing a console game or a whole console, with the Trash and the kept-saves
// folder inside the scene's scratch directory — never the user's real folders.
@Suite("Console removal", .serialized)
@MainActor
struct ConsoleUninstallTests {

    // uninstall.trash drops into the scene's bin/, kept saves into kept-saves/,
    // and confirmGameRemoval answers for the person at the dialog.
    private func arm(_ scene: ConsoleScene, answer: RemovalAnswer = .moveToTrash(keepSaves: true),
                     plans: Box<[ConsoleGameRemoval]> = Box([])) -> Box<[ConsoleGameRemoval]> {
        let bin = scene.work.appending(path: "bin", directoryHint: .isDirectory)
        scene.center.uninstall.trash = { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appending(path: url.lastPathComponent))
        }
        scene.center.uninstall.saves = scene.work.appending(path: "kept-saves", directoryHint: .isDirectory)
        scene.center.confirmGameRemoval = { plans.value.append($0); return answer }
        return plans
    }

    private func item(_ scene: ConsoleScene, _ id: String) throws -> GameMenuItem? {
        let game = try #require(scene.library.game(id))
        return GameMenu.items(for: game, in: scene.library, consoles: scene.center).first { $0.action == .uninstall }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func writeSave(_ scene: ConsoleScene, for game: ConsoleGame) throws -> (srm: URL, state: URL) {
        let srm = scene.paths.saves.appending(path: "Snes9x/\(game.contentName).srm")
        let state = scene.paths.states.appending(path: "Snes9x/\(game.contentName).state1")
        for url in [srm, state] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("save".utf8).write(to: url)
        }
        return (srm, state)
    }

    @Test("Saves and states are matched by their exact stem: Dr never takes Dr. Mario's")
    func exactStem() throws {
        for name in ["Dr.srm", "Dr.rtc", "Dr.sav"] { #expect(ConsoleUninstall.isSave(name, of: "Dr"), "\(name)") }
        for name in ["Dr. Mario.srm", "Dr. Mario", "Dr.srm.bak", "Dr.", "Drx.srm"] {
            #expect(!ConsoleUninstall.isSave(name, of: "Dr"), "\(name)")
        }
        for name in ["Dr.state", "Dr.state1", "Dr.state12.png", "Dr.state.auto", "Dr.state.auto.png", "Dr.state.png"] {
            #expect(ConsoleUninstall.isState(name, of: "Dr"), "\(name)")
        }
        for name in ["Dr. Mario.state1", "Dr.state1x", "Dr.statefoo", "Dr.state1.png.bak"] {
            #expect(!ConsoleUninstall.isState(name, of: "Dr"), "\(name)")
        }

        let work = try scratchDirectory("exact-stem")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let core = "Mesen"
        var files: [String: URL] = [:]
        for (key, folder, name) in [("dr-srm", paths.saves, "Dr.srm"), ("mario-srm", paths.saves, "Dr. Mario.srm"),
                                    ("dr-state", paths.states, "Dr.state2"), ("mario-state", paths.states, "Dr. Mario.state1")] {
            let url = folder.appending(path: "\(core)/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            files[key] = url.resolvingSymlinksInPath()
        }
        let dr = ConsoleGame(console: "nes", name: "Dr", databaseName: nil,
                             file: work.appending(path: "Dr.nes"), identifiedBy: .chosen)
        #expect(dr.contentName == "Dr")
        let found = Set(ConsoleUninstall.saveFiles(for: dr, in: paths).map { $0.resolvingSymlinksInPath() })
        #expect(found == [files["dr-srm"]!, files["dr-state"]!])
    }

    @Test("A file in the user's folders shows Remove from Library…; a copy in Cartouche's shows Move ROM to Trash…")
    func itemTitle() async throws {
        let scene = try await ConsoleScene("remove-title")
        defer { scene.remove() }
        let own = try await scene.addGame(console: "snes", name: "Quest")

        let roms = scene.paths.root.appending(path: "roms", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        let copiedFile = roms.appending(path: "Copied.sfc")
        try ConsoleFixtures.homebrewSNES(fill: 0x77).write(to: copiedFile)
        let copied = ConsoleGame(console: "snes", name: "Copied", databaseName: nil, file: copiedFile, identifiedBy: .chosen)
        try await scene.center.store.add([copied])
        // A file gone from disk is only ever a library record, wherever it lived
        let missing = ConsoleGame(console: "snes", name: "Missing", databaseName: nil,
                                  file: roms.appending(path: "Missing.sfc"), identifiedBy: .chosen)
        try await scene.center.store.add([missing])
        await scene.center.reload()

        let ownItem = try #require(try item(scene, own.id))
        #expect(ownItem.title == "Remove from Library…")
        #expect(ownItem.destructive == true)
        #expect(ownItem.disabled == false)
        #expect(try item(scene, copied.id)?.title == "Move ROM to Trash…")
        #expect(try item(scene, missing.id)?.title == "Remove from Library…")
        #expect(scene.center.ownedROMs == [copied.id])

        // Menus use the last reload's answer, not filesystem probes during view updates.
        try FileManager.default.removeItem(at: copiedFile)
        #expect(try item(scene, copied.id)?.title == "Move ROM to Trash…")
        await scene.center.reload()
        #expect(scene.center.ownedROMs.isEmpty)
        #expect(try item(scene, copied.id)?.title == "Remove from Library…")
    }

    @Test("Remove from Library: the ROM stays, the record goes, saves and states move to the Trash")
    func removeFromLibrary() async throws {
        let scene = try await ConsoleScene("remove-library")
        defer { scene.remove() }
        let plans = arm(scene, answer: .moveToTrash(keepSaves: false))
        let game = try await scene.addGame(console: "snes", name: "Quest")
        let (srm, state) = try writeSave(scene, for: game)

        await scene.center.removeGame(game.id)

        #expect(plans.value.first?.ownsROM == false)
        #expect(plans.value.first?.hasSaves == true)
        #expect(exists(game.fileURL))
        #expect(exists(scene.work.appending(path: "bin/Quest.srm")))
        #expect(exists(scene.work.appending(path: "bin/Quest.state1")))
        #expect(!exists(srm) && !exists(state))
        #expect(scene.center.game(game.id) == nil)
        #expect(await scene.center.store.game(game.id) == nil)
        #expect(scene.library.game(game.id) == nil)
    }

    @Test("Move ROM to Trash: a copied .cue takes its track; keep-saves copies first, then everything moves")
    func moveROMToTrash() async throws {
        let scene = try await ConsoleScene("remove-copied")
        defer { scene.remove() }
        let plans = arm(scene)
        let roms = scene.paths.root.appending(path: "roms", directoryHint: .isDirectory)
        let cue = try ConsoleFixtures.disc("Saga", serial: "SLUS_999.99", in: roms)
        let game = ConsoleGame(console: "ps1", name: "Saga", databaseName: nil, file: cue, identifiedBy: .chosen)
        await scene.center.add(["ps1"])
        try await scene.center.store.add([game])
        await scene.center.reload()
        _ = try writeSave(scene, for: game)

        let png = scene.work.appending(path: "cover.png")
        try SteamFixture.png("cover", size: CGSize(width: 30, height: 30), hue: 0.5).write(to: png)
        scene.library.setCover(png, for: game.id)
        #expect(scene.library.coverOverride(for: game.id) != nil)

        await scene.center.removeGame(game.id)

        let plan = try #require(plans.value.first)
        #expect(plan.ownsROM)
        #expect(plan.roms.map(\.lastPathComponent).sorted() == ["Saga.bin", "Saga.cue"])
        #expect(exists(scene.work.appending(path: "bin/Saga.cue")))
        #expect(exists(scene.work.appending(path: "bin/Saga.bin")))
        #expect(exists(scene.work.appending(path: "bin/Saga.srm")))
        #expect(!exists(cue))
        // Kept copies keep their layout under the console-content folder
        #expect(exists(scene.work.appending(path: "kept-saves/ps1-Saga/saves/Snes9x/Saga.srm")))
        #expect(scene.library.game(game.id) == nil)
        #expect(scene.library.coverOverride(for: game.id) == nil)
    }

    @Test("A saves folder linked into iCloud Drive is the user's: its files are never listed or moved")
    func linkedSavesStay() async throws {
        let scene = try await ConsoleScene("remove-linked-saves")
        defer { scene.remove() }
        let plans = arm(scene)
        // paths.saves is a link out to the user's own cloud folder, not Cartouche's
        let cloud = scene.work.appending(path: "iCloud Drive/saves", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scene.paths.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scene.paths.saves, withDestinationURL: cloud)
        let game = try await scene.addGame(console: "snes", name: "Clouded")
        let srm = cloud.appending(path: "Snes9x/\(game.contentName).srm")
        try FileManager.default.createDirectory(at: srm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cloud save".utf8).write(to: srm)
        let state = try writeSave(scene, for: game).state

        await scene.center.removeGame(game.id)

        #expect(plans.value.first?.saves.map(\.lastPathComponent) == ["Clouded.state1"])
        #expect(exists(srm))
        #expect(exists(scene.work.appending(path: "bin/Clouded.state1")))
        #expect(!exists(state))
        #expect(!exists(scene.work.appending(path: "kept-saves/snes-Clouded/saves/Snes9x/Clouded.srm")))
    }

    @Test("While the game plays the item is disabled and removal refuses with a problem, not a move")
    func busyRefuses() async throws {
        let scene = try await ConsoleScene("remove-busy")
        defer { scene.remove() }
        let plans = arm(scene)
        let game = try await scene.addGame(console: "snes", name: "Quest")
        scene.center.playing = Playing(gameID: game.id, phase: .playing)

        #expect(try item(scene, game.id)?.disabled == true)
        await scene.center.removeGame(game.id)

        #expect(scene.center.problem == "Quest is playing. Quit the game first.")
        #expect(plans.value.isEmpty)
        #expect(exists(game.fileURL))
        #expect(scene.center.game(game.id) != nil)
    }

    @Test("Cancel keeps the record, the files and the library row")
    func cancelLeavesEverything() async throws {
        let scene = try await ConsoleScene("remove-cancel")
        defer { scene.remove() }
        let plans = arm(scene, answer: .cancel)
        let game = try await scene.addGame(console: "snes", name: "Quest")
        let (srm, _) = try writeSave(scene, for: game)

        await scene.center.removeGame(game.id)

        #expect(plans.value.count == 1)
        #expect(exists(game.fileURL) && exists(srm))
        #expect(scene.center.game(game.id) != nil)
        #expect(scene.library.game(game.id) != nil)
        #expect(!exists(scene.work.appending(path: "bin")))
    }

    @Test("Remove a console: its core files move to the Trash, a shared core waits, games are hidden not deleted")
    func removeConsole() async throws {
        let scene = try await ConsoleScene("remove-console")
        defer { scene.remove() }
        await scene.center.add(["gb", "gbc"])
        let boy = try await scene.addGame(console: "gb", name: "Puzzle", data: ConsoleFixtures.homebrewGB(title: "PUZZLE"), ext: "gb")
        let color = try await scene.addGame(console: "gbc", name: "Maze", data: ConsoleFixtures.homebrewGB(title: "MAZE", fill: 1), ext: "gbc")
        let confirmations = Box<[ConsoleRemoval]>([])
        scene.center.confirmRemoval = { confirmations.value.append($0); return true }

        // The sameboy core is still gbc's: nothing moves, both games' files stay, gb's game leaves the list
        await scene.center.remove("gb")
        #expect(confirmations.value.last?.files == [])
        #expect(confirmations.value.last?.games == 1)
        #expect(scene.coresFolder == ["sameboy_libretro.dylib"])
        #expect(scene.center.games(of: "gb").isEmpty)
        #expect(await scene.center.store.game(boy.id) != nil)
        #expect(exists(boy.fileURL) && exists(color.fileURL))

        // The last console on the core takes it out
        await scene.center.remove("gbc")
        #expect(confirmations.value.last?.files.map(\.lastPathComponent).sorted() == ["sameboy_libretro.dylib", "sameboy_libretro.info"])
        #expect(scene.coresFolder.isEmpty)
        #expect(exists(scene.work.appending(path: "bin/sameboy_libretro.dylib")))
        #expect(exists(scene.work.appending(path: "bin/sameboy_libretro.info")))
        #expect(await scene.center.store.game(color.id) != nil)
        #expect(exists(color.fileURL))
    }

    @Test("A console without a core or with a game playing confirms nothing and removes nothing")
    func removeConsoleGuards() async throws {
        let scene = try await ConsoleScene("remove-guards")
        defer { scene.remove() }
        await scene.center.add(["switch", "snes"])
        let game = try await scene.addGame(console: "snes", name: "Quest")
        let confirmations = Box<[ConsoleRemoval]>([])
        scene.center.confirmRemoval = { confirmations.value.append($0); return true }

        // "switch" plays in a standalone emulator: no core files to list
        await scene.center.remove("switch")
        #expect(confirmations.value.last?.files == [])
        #expect(confirmations.value.last?.games == 0)
        #expect(!scene.center.isAdded("switch"))

        // A game of the console playing refuses before any confirmation
        scene.center.playing = Playing(gameID: game.id, phase: .playing)
        await scene.center.remove("snes")
        #expect(scene.center.problem == "Super Nintendo is playing. Quit the game first.")
        #expect(confirmations.value.count == 1)
        #expect(scene.center.isAdded("snes"))
        #expect(scene.center.menu(for: "snes").last?.disabled == true)
    }

    @Test("Settings > Consoles removes through the same confirmation, then its list and the library update")
    func settingsRemoveGoesThroughCenter() async throws {
        let scene = try await ConsoleScene("remove-settings")
        defer { scene.remove() }
        await scene.center.add(["snes"])
        _ = try await scene.addGame(console: "snes", name: "Quest")
        await scene.settings.refresh()
        let row = try #require(scene.settings.consoles.first { $0.console.id == "snes" })
        let confirmations = Box<[ConsoleRemoval]>([])
        scene.center.confirmRemoval = { confirmations.value.append($0); return true }

        await scene.settings.remove(row.console)
        #expect(confirmations.value.count == 1)
        #expect(scene.settings.consoles.isEmpty)
        #expect(scene.library.consoles.isEmpty)
        #expect(scene.library.consoleGames.isEmpty)

        // A declined confirmation leaves the console in place
        await scene.center.add(["snes"])
        scene.center.confirmRemoval = { _ in false }
        await scene.settings.remove(row.console)
        #expect(scene.center.isAdded("snes"))
        #expect(scene.settings.consoles.map(\.id) == ["snes"])
    }
}
