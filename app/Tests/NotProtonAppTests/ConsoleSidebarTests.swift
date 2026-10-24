import CryptoKit
import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Consoles in the sidebar", .serialized)
@MainActor
struct ConsoleSidebarTests {

    private func sidebar(_ scene: ConsoleScene) -> some View {
        LibrarySidebar(model: scene.library).environment(scene.center).frame(width: 280, height: 520)
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Add two consoles: + opens Add Consoles, NES and Game Boy join the sidebar with their two cores and no other")
    func addTwoConsoles() async throws {
        let scene = try await ConsoleScene("add")
        defer { scene.remove() }
        await scene.library.load()
        await scene.center.reload()

        // The + next to Consoles opens Add Consoles, not the Add Games sheet
        #expect(!scene.library.showAddConsoles)
        scene.library.showAddConsoles = true
        #expect(!scene.library.showConsoleImport)

        var choice = AddConsolesChoice()
        choice.toggle("nes")
        choice.toggle("gb")
        #expect(choice.addTitle == "Add 2 Consoles")
        let sheetTexts = try await renderedTexts(AddConsolesSheet(center: scene.center, choice: choice),
                                                 size: CGSize(width: 660, height: 560), named: "add-consoles")
        #expect(sheetTexts.contains("Add Consoles"))
        #expect(sheetTexts.contains("Add 2 Consoles"))
        let tile = try await renderedTexts(AddConsoleTile(console: ConsoleCatalog.console("ps1")!, added: false, picked: false,
                                                       found: 0, toggle: {}).frame(width: 200),
                                           size: CGSize(width: 220, height: 110))
        #expect(tile.contains("Needs BIOS"))
        for dark in [false, true] {
            _ = try await renderedTexts(AddConsolesSheet(center: scene.center, choice: choice),
                                        size: CGSize(width: 660, height: 560), named: "add-consoles", dark: dark)
        }

        await scene.center.add(choice.picked)

        #expect(scene.library.consoles == ["nes", "gb"])
        #expect(scene.coresFolder == ["nestopia_libretro.dylib", "sameboy_libretro.dylib"])
        #expect(scene.coreRequests == ["/nightly/nestopia_libretro.dylib.zip", "/nightly/sameboy_libretro.dylib.zip"])
        #expect(scene.center.problem == nil)
        print("evidence: sidebar consoles \(scene.library.consoles), cores folder \(scene.coresFolder), core downloads \(scene.coreRequests)")

        let texts = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 520), named: "sidebar-consoles")
        _ = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 520), named: "sidebar-consoles", dark: true)
        #expect(seen(texts, "Nintendo Entertainment"))
        #expect(seen(texts, "Game Boy"))
        #expect(!seen(texts, "PlayStation"))

        let again = try await renderedTexts(AddConsolesSheet(center: scene.center), size: CGSize(width: 660, height: 560))
        #expect(again.filter { $0 == "Added" }.count == 2)
    }

    @Test("Remove a console: right-click PlayStation, Remove; it leaves the sidebar, its core goes, its games stay on disk")
    func removeConsole() async throws {
        let scene = try await ConsoleScene("remove")
        defer { scene.remove() }
        await scene.library.load()
        await scene.center.add(["ps1", "snes"])
        #expect(scene.coresFolder == ["snes9x_libretro.dylib", "swanstation_libretro.dylib"])

        let games = scene.work.appending(path: "My Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        var files: [URL] = []
        for name in ["Homebrew One", "Homebrew Two"] {
            let bin = games.appending(path: "\(name).bin")
            try Data(repeating: 0x5A, count: 4096).write(to: bin)
            let cue = games.appending(path: "\(name).cue")
            try "FILE \"\(name).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
            files += [bin, cue]
            try await scene.center.store.add([ConsoleGame(console: "ps1", name: name, databaseName: nil, file: cue,
                                                          identifiedBy: .chosen)])
        }
        await scene.center.reload()
        let before = try files.map(Self.sha256)
        #expect(scene.library.games(in: .source(.console("ps1"))).count == 2)

        let menu = scene.center.menu(for: "ps1")
        #expect(menu.map(\.title) == ["Add PlayStation Games…", "Remove PlayStation (2 games stay on disk)…"])
        #expect(menu.last?.destructive == true)
        #expect(menu.last?.disabled == false)
        // The confirmation names the core files that move to the Trash; the test Trash is the scene's bin/
        let removals = Box<[ConsoleRemoval]>([])
        scene.center.confirmRemoval = { removals.value.append($0); return true }
        scene.library.selection = .source(.console("ps1"))
        await scene.center.perform(.remove, on: "ps1")

        #expect(removals.value.first?.games == 2)
        #expect(removals.value.first?.files.map(\.lastPathComponent).sorted() == ["swanstation_libretro.dylib", "swanstation_libretro.info"])
        #expect(FileManager.default.fileExists(atPath: scene.work.appending(path: "bin/swanstation_libretro.dylib").path(percentEncoded: false)))
        #expect(scene.library.consoles == ["snes"])
        #expect(scene.library.selection == .all)
        #expect(scene.coresFolder == ["snes9x_libretro.dylib"])
        #expect(try files.map(Self.sha256) == before)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        print("evidence: after Remove, sidebar \(scene.library.consoles), cores \(scene.coresFolder), \(files.count) game files unchanged")

        let texts = try await renderedTexts(sidebar(scene), size: CGSize(width: 280, height: 520), named: "sidebar-after-remove")
        #expect(!seen(texts, "PlayStation"))
        #expect(seen(texts, "Super Nintendo"))

        // Adding it back brings its games back
        await scene.center.add(["ps1"])
        #expect(scene.library.games(in: .source(.console("ps1"))).count == 2)
    }

    @Test("The Remove item names how many games stay on disk")
    func removeWording() async throws {
        let scene = try await ConsoleScene("wording")
        defer { scene.remove() }
        await scene.center.add(["gba"])
        #expect(scene.center.menu(for: "gba").last?.title == "Remove Game Boy Advance…")
        let file = scene.work.appending(path: "a.gba")
        try Data([1, 2, 3]).write(to: file)
        try await scene.center.store.add([ConsoleGame(console: "gba", name: "A", databaseName: nil, file: file, identifiedBy: .chosen)])
        await scene.center.reload()
        #expect(scene.center.menu(for: "gba").last?.title == "Remove Game Boy Advance (its game stays on disk)…")
        #expect(scene.center.menu(for: "gba").first?.title == "Add Game Boy Advance Games…")
        await scene.center.perform(.addGames, on: "gba")
        #expect(scene.library.showAddGames)
    }
}
