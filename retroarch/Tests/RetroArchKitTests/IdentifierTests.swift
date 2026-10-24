import Foundation
import Synchronization
import Testing

@testable import RetroArchKit

@Suite("Identifying console games")
struct IdentifierTests {

    @Test("A multi-gigabyte Switch container is offered without hashing it or claiming a database match")
    func largeSwitchContainer() async throws {
        let scene = try Scene("large-switch")
        defer { try? FileManager.default.removeItem(at: scene.work) }
        let file = try scene.write("Homebrew.nsp", Data("PFS0".utf8))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try handle.close()
        let start = ContinuousClock.now
        let found = await scene.identifier.identify(file)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(found.candidates == ["switch"])
        #expect(!found.isRecognized)
        #expect(found.crc == nil)
    }

    struct Scene {
        let work: URL
        let paths: RetroArchPaths
        let identifier: Identifier

        init(_ label: String) throws {
            work = try scratchFolder("identify-\(label)")
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            try FixtureDatabase.install(in: paths)
            identifier = Identifier(database: FixtureDatabase.offline(paths))
        }

        func write(_ name: String, _ data: Data) throws -> URL {
            let url = work.appending(path: "games/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        var games: URL { work.appending(path: "games", directoryHint: .isDirectory) }
    }

    @Test func crc32IsZlibs() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
        // Computed with Python's zlib.crc32, in rows.json
        #expect(CRC32.checksum(Homebrew.snes()) == 0x3FA8_62E9)
        #expect(CRC32.checksum(Homebrew.gb("CARTOUCHE QUEST")) == 0x0E8B_3192)
        var pieces = CRC32()
        let data = Homebrew.snes()
        pieces.update(data.prefix(1000))
        pieces.update(data.dropFirst(1000))
        #expect(pieces.value == 0x3FA8_62E9)
    }

    @Test func theDatabaseFormatReadsBackWhatLibretroDBWrites() throws {
        let rows = try #require(try FixtureDatabase.rows()["Sony - PlayStation"])
        let read = try RDB.parse(RDB.write(rows))
        #expect(read == rows)
        #expect(throws: RDB.Problem.notADatabase) { try RDB.parse(Data("not a database".utf8)) }
    }

    @Test func recordedRowsNameTheRealGames() async throws {
        let scene = try Scene("rows")
        let snes = try #require(ConsoleCatalog.console("snes"))
        let metroid = try #require(await scene.identifier.database.match(crc: 0xD63E_D5F8, in: snes))
        #expect(metroid.name == "Super Metroid (Japan, USA) (En,Ja)")
        #expect(GameTitle.display(metroid.name) == "Super Metroid")
        let ps1 = try #require(ConsoleCatalog.console("ps1"))
        #expect(await scene.identifier.database.match(serial: "SCUS-94900", in: ps1)?.name == "Crash Bandicoot (USA)")
        #expect(await scene.identifier.database.match(serial: "slus-00594", in: ps1)?.name == "Metal Gear Solid (USA) (Disc 1) (Rev 1)")
        // Of two rows with one name, the verified dump without TOSEC flags
        #expect(ContentDatabase.best([DatabaseEntry(name: "A [h]"), DatabaseEntry(name: "A")])?.name == "A")
    }

    @Test func titlesReadAsTheBoxDoes() {
        #expect(GameTitle.display("Super Metroid (Japan, USA) (En,Ja)") == "Super Metroid")
        #expect(GameTitle.display("Legend of Zelda, The - A Link to the Past (USA)") == "The Legend of Zelda: A Link to the Past")
        #expect(GameTitle.display("Metal Gear Solid (USA) (Disc 1) (Rev 1)") == "Metal Gear Solid")
        #expect(GameTitle.display("Sonic The Hedgehog 2 (World)") == "Sonic The Hedgehog 2")
        #expect(GameTitle.display("Mario & Luigi - Superstar Saga (USA)") == "Mario & Luigi: Superstar Saga")
        #expect(GameTitle.display("Super Metroid (Japan, USA)[h]") == "Super Metroid")
    }

    @Test func aKnownCartridgeIsNamedByItsChecksumWithinTwoSeconds() async throws {
        let scene = try Scene("cart")
        let file = try scene.write("my_dump.sfc", Homebrew.snes())
        let asked = ContinuousClock.now
        let found = await scene.identifier.identify(file)
        let took = ContinuousClock.now - asked
        #expect(found.name == "Cartouche Homebrew")
        #expect(found.console == "snes")
        #expect(found.identifiedBy == .checksum)
        #expect(found.databaseName == "Cartouche Homebrew (World)")
        #expect(took < .seconds(2), "identified after \(took)")
        print("evidence: \(file.lastPathComponent) -> \(found.name), \(found.console ?? "-"), \(found.identifiedBy.map(\.rawValue) ?? "-") after \(took)")

        // With a copier's 512-byte header in front, the same game
        let headed = try scene.write("headed.smc", Data(repeating: 0, count: 512) + Homebrew.snes())
        #expect(await scene.identifier.identify(headed).name == "Cartouche Homebrew")
    }

    @Test func aZippedCartridgeIsKnownByTheCRCInItsDirectory() async throws {
        let scene = try Scene("zip")
        let zip = try zipFixture(["quest.gb": Homebrew.gb("CARTOUCHE QUEST")], in: scene.work)
        let file = try scene.write("quest.zip", zip)
        let found = await scene.identifier.identify(file)
        #expect(Zip.members(file).first?.crc == 0x0E8B_3192)
        #expect(found.name == "Cartouche Quest")
        #expect(found.console == "gb")
        #expect(found.identifiedBy == .checksum)
    }

    @Test func aDiscIsKnownByItsSerial() async throws {
        let scene = try Scene("disc")
        let cue = try Homebrew.disc("Test Disc", serial: "SLUS_999.01", in: scene.games)
        #expect(DiscSerial.playStation(cue.deletingPathExtension().appendingPathExtension("bin")) == "SLUS-99901")
        let found = await scene.identifier.identify(cue)
        #expect(found.name == "Cartouche Test Disc")
        #expect(found.console == "ps1")
        #expect(found.identifiedBy == .discID)
        // The track goes with its sheet, not on its own
        #expect(Identifier.files(in: [scene.games]).map(\.lastPathComponent) == ["Test Disc.cue"])
    }

    @Test func aMultiDiscSetWithAnM3UIsOneGame() async throws {
        let scene = try Scene("m3u")
        let set = scene.games.appending(path: "Saga", directoryHint: .isDirectory)
        try Homebrew.disc("Saga (Disc 1)", serial: "SLUS_999.02", in: set)
        try Homebrew.disc("Saga (Disc 2)", serial: "SLUS_999.03", in: set)
        try "Saga (Disc 1).cue\nSaga (Disc 2).cue\n".write(to: set.appending(path: "Saga.m3u"), atomically: true, encoding: .utf8)

        let all = await scene.identifier.identify([scene.games])
        #expect(all.count == 1)
        let game = try #require(all.first)
        #expect(game.file.lastPathComponent == "Saga.m3u")
        #expect(game.discs.map(\.lastPathComponent) == ["Saga (Disc 1).cue", "Saga (Disc 2).cue"])
        #expect(game.name == "Cartouche Test Saga")
        #expect(game.databaseName == "Cartouche Test Saga (World) (Disc 1)")
        #expect(game.identifiedBy == .discID)
        #expect(game.game()?.isMultiDisc == true)
        print("evidence: \(all.map { "\($0.file.lastPathComponent) -> \($0.name), \($0.discs.count) discs, \($0.identifiedBy?.rawValue ?? "-")" })")
    }

    @Test func anUnknownHomebrewAsksForAConsole() async throws {
        let scene = try Scene("unknown")
        let file = try scene.write("my_homebrew.gba", Homebrew.gba("MY HOMEBREW"))
        let found = await scene.identifier.identify(file)
        #expect(!found.isRecognized)
        #expect(found.identifiedBy == nil)
        #expect(found.name == "my_homebrew")
        #expect(found.candidates == ["gba"])
        // Nothing to add until a console is chosen
        #expect(found.game() == nil)
        #expect(found.game(console: "gba")?.identifiedBy == .chosen)
        #expect(found.game(console: "gba")?.console == "gba")
    }

    @Test func aCartridgeWithoutItsHeaderIsNotAGame() async throws {
        let scene = try Scene("fake")
        // The name claims Game Boy; the bytes are not a cartridge's
        for name in ["fake.gb", "fake.gbc", "fake.gba", "fake.nds", "fake.nes"] {
            let file = try scene.write(name, Data(repeating: 0x7E, count: 8192))
            let found = await scene.identifier.identify(file)
            #expect(!found.isRecognized, "\(name)")
            #expect(found.candidates.isEmpty, "\(name)")
            #expect(found.game() == nil)
        }
    }

    @Test func workingCopiesAndLibrariesAreNeverScanned() throws {
        let scene = try Scene("fences")
        let repo = scene.games.appending(path: "clone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        _ = try scene.write("clone/roms/quest.gb", Homebrew.gb("CARTOUCHE QUEST"))
        // A linked worktree's .git is a file, not a folder
        let worktree = scene.games.appending(path: "wt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree.appending(path: "roms"), withIntermediateDirectories: true)
        try Data().write(to: worktree.appending(path: ".git"))
        try Homebrew.gb("CARTOUCHE QUEST").write(to: worktree.appending(path: "roms/quest.gb"))
        let library = scene.games.appending(path: "Library/Cartouche", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Homebrew.gb("CARTOUCHE QUEST").write(to: library.appending(path: "quest.gb"))

        #expect(Identifier.files(in: [scene.games]).map(\.lastPathComponent).isEmpty)
        // The fences refuse such folders even as the walk's own root
        #expect(Identifier.files(in: [repo]).isEmpty)
        #expect(Identifier.files(in: [worktree]).isEmpty)
        #expect(Identifier.files(in: [library]).isEmpty)
        // An explicitly named file still identifies — the fence bounds walks
        let file = scene.games.appending(path: "quest.gb")
        try Homebrew.gb("CARTOUCHE QUEST").write(to: file)
        #expect(Identifier.files(in: [file]).map(\.lastPathComponent) == ["quest.gb"])
    }

    @Test func otherFilesAreLeftOut() throws {
        let scene = try Scene("others")
        _ = try scene.write("readme.txt", Data("hello".utf8))
        _ = try scene.write("setup.exe", Data([0x4D, 0x5A]))
        _ = try scene.write("quest.gb", Homebrew.gb("CARTOUCHE QUEST"))
        #expect(Identifier.files(in: [scene.games]).map(\.lastPathComponent) == ["quest.gb"])
    }

    @Test func aConsolesDatabaseIsDownloadedOnceWhenFirstNeeded() async throws {
        let work = try scratchFolder("db-download")
        let paths = RetroArchPaths(root: work)
        let rows = try FixtureDatabase.rows()
        let asked = Mutex<[String]>([])
        let database = ContentDatabase(paths: paths, source: DatabaseSource(base: URL(string: "https://db.example/rdb/")!)) { url in
            asked.withLock { $0.append(url.absoluteString) }
            let system = url.deletingPathExtension().lastPathComponent
            return (RDB.write(rows[system] ?? []), rows[system] == nil ? 404 : 200)
        }
        let identifier = Identifier(database: database)
        let file = work.appending(path: "quest.gb")
        try Homebrew.gb("CARTOUCHE QUEST").write(to: file)
        #expect(await identifier.identify(file).name == "Cartouche Quest")
        #expect(await identifier.identify(file).name == "Cartouche Quest")
        // Only the Game Boy's, escaped, and only once
        #expect(asked.withLock { $0 } == ["https://db.example/rdb/Nintendo%20-%20Game%20Boy.rdb"])
        #expect(FileManager.default.fileExists(atPath: paths.database.appending(path: "Nintendo - Game Boy.rdb").path))
    }

    @Test func offlineWithoutTheDatabaseTheFileIsNotRecognized() async throws {
        let work = try scratchFolder("db-offline")
        let identifier = Identifier(database: FixtureDatabase.offline(RetroArchPaths(root: work)))
        let file = work.appending(path: "quest.gb")
        try Homebrew.gb("CARTOUCHE QUEST").write(to: file)
        let found = await identifier.identify(file)
        #expect(!found.isRecognized)
        #expect(found.candidates == ["gb"])
    }

    @Test(.enabled(if: Rig.network, "set CARTOUCHE_NETWORK_TESTS=1"))
    func withTheRealDatabaseACartridgeIsNamedWithinTwoSeconds() async throws {
        let work = try scratchFolder("db-real")
        let paths = RetroArchPaths(root: work)
        let identifier = Identifier(database: ContentDatabase(paths: paths))
        let snes = try #require(ConsoleCatalog.console("snes"))
        #expect(await identifier.database.prepare(snes))
        let metroid = try #require(await identifier.database.match(crc: 0xD63E_D5F8, in: snes))
        #expect(metroid.name == "Super Metroid (Japan, USA) (En,Ja)")
        // A cartridge as large as Super Metroid, 3 MiB, identified against it
        let file = work.appending(path: "large.sfc")
        try (Data(repeating: 0x11, count: 3 * 1024 * 1024 - 32768) + Homebrew.snes()).write(to: file)
        let fresh = Identifier(database: ContentDatabase(paths: paths))
        let asked = ContinuousClock.now
        let found = await fresh.identify(file)
        let took = ContinuousClock.now - asked
        #expect(took < .seconds(2))
        print("evidence: real SNES database, \(found.isRecognized ? found.name : "not recognized") after \(took) for 3 MiB, Super Metroid row \(metroid.name)")
    }
}
