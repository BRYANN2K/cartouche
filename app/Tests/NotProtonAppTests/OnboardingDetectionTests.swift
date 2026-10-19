import Foundation
import Synchronization
import Testing

@testable import NotProtonApp

// Task 2.1: what the first launch finds before it asks anything. Steam is the
// fixture Steam folder, the controller is a stand-in, and the home folder is a
// scratch folder: nothing reads the real ones.
@Suite("Onboarding detection")
struct OnboardingDetectionTests {

    static func touch(_ files: [String], in folder: URL) throws {
        for file in files {
            let url = folder.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rom".utf8).write(to: url)
        }
    }

    @Test("Steam signed in, a DualSense and ~/Games/ROMs: the welcome step lists all three within 3 seconds")
    func foundList() async throws {
        let fixture = try SteamFixture("detect")
        defer { fixture.remove() }
        // Every game the account owns, as the running Steam client exports them
        try fixture.writeExport()
        let home = fixture.root.appending(path: "home")
        try Self.touch(["Games/ROMs/Tetris.gb", "Games/ROMs/Zelda.gb", "Games/ROMs/gba/Metroid.gba",
                        "Games/ROMs/psx/Crash.cue", "Games/ROMs/notes.txt"], in: home)
        let importer = fixture.importer(running: false)
        let scan = MacScan(
            steam: { MacScan.steam(importer) },
            crossOver: { [] },
            portingToolkit: { [FoundRunner(name: "Game Porting Toolkit 3.0")] },
            controllers: { [FoundController(name: "DualSense Wireless Controller", battery: 80)] },
            folders: { GameFolderScan(home: home).run() })

        let clock = ContinuousClock()
        let start = clock.now
        let found = await scan.run()
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(3))
        #expect(found.complete)
        #expect(found.steam == FoundSteam(account: "player42", games: SteamFixture.apps.count))
        #expect(FoundList.steamLine(try #require(found.steam)) == "Signed in as player42, 8 games")
        #expect(found.controllers.map(\.name) == ["DualSense Wireless Controller"])
        let folder = try #require(found.folders.first)
        #expect(found.folders.count == 1)
        #expect(folder.shortPath(home: home) == "~/Games/ROMs")
        #expect(folder.games == 4)
        #expect(folder.consoles == ["gb": 2, "gba": 1, "ps1": 1])
        #expect(FoundList.folderLine(folder) == "4 console games, for Game Boy, Game Boy Advance, and PlayStation")
        print("detection took \(elapsed)")
    }

    @Test("A source still reading at the deadline does not hold the list back")
    func deadline() async {
        let scan = MacScan(
            steam: { Thread.sleep(forTimeInterval: 5); return FoundSteam(account: "late", games: 1) },
            crossOver: { [FoundRunner(name: "CrossOver 26.3")] },
            portingToolkit: { [] },
            controllers: { [] },
            folders: { [] })
        let clock = ContinuousClock()
        let start = clock.now
        let found = await scan.run(deadline: .milliseconds(300))
        #expect(clock.now - start < .seconds(2))
        #expect(!found.complete)
        #expect(found.steam == nil)
        #expect(found.crossOver == [FoundRunner(name: "CrossOver 26.3")])
        #expect(MacScan.deadline == .seconds(3))
    }

    @Test("Only game-like folders in the home folder are offered, never protected or outside ones")
    func folderRules() throws {
        let home = try scratchDirectory("detect-home")
        defer { try? FileManager.default.removeItem(at: home) }
        // Protected by macOS: never read, even through a link
        try Self.touch(["Documents/ROMs/Mario.sfc"], in: home)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "ROMs"),
                                                   withDestinationURL: home.appending(path: "Documents/ROMs"))
        // Games holds ROMs, which is offered first; Games itself only for what is outside it
        try Self.touch(["Games/ROMs/Sonic.md", "Games/Arcade/Pong.a26", "Games/Steam/readme.txt"], in: home)
        // A folder with no console game is not offered
        try Self.touch(["Emulation/saves/slot1.txt"], in: home)

        let found = GameFolderScan(home: home).run()
        #expect(found.map { $0.shortPath(home: home) } == ["~/Games/ROMs", "~/Games"])
        #expect(found.first?.consoles == ["genesis": 1])
        #expect(found.last?.consoles == ["atari2600": 1])
    }

    @Test("Without Steam, nothing found is an empty list")
    func nothing() async {
        let scan = MacScan(steam: { nil }, crossOver: { [] }, portingToolkit: { [] }, controllers: { [] }, folders: { [] })
        let found = await scan.run()
        #expect(found.isEmpty)
        #expect(found.complete)
        #expect(FoundList.steamLine(FoundSteam(account: nil, games: 3)) == "Not signed in")
    }

    @Test("A Steam that is not installed is not listed")
    func steamMissing() throws {
        let fixture = try SteamFixture("detect-missing")
        defer { fixture.remove() }
        #expect(MacScan.steam(fixture.importer(installed: false, running: false)) == nil)
    }

    @MainActor
    @Test("The welcome step renders the found list, light and dark, macOS 26 and 15 looks")
    func welcomeRenders() async throws {
        let scene = try OnboardingScene("welcome")
        defer { scene.remove() }
        scene.findings.portingToolkit = [FoundRunner(name: "Game Porting Toolkit 3.0")]
        let model = try scene.model()
        model.presentIfDue()
        await model.prepare()
        #expect(model.step == .welcome)
        #expect(model.findings?.steam?.account == "player42")
        await scene.render(model, named: "onboarding-welcome")
    }
}
