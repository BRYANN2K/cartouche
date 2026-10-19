import Foundation
import Testing

@testable import RetroArchKit

@Suite("Console catalog")
struct CatalogTests {

    @Test func everyConsoleNamesItsSystemCoreGlyphAndFiles() {
        for console in ConsoleCatalog.all {
            #expect(!console.system.isEmpty, "\(console.id) has no libretro system name")
            #expect(console.system.contains(" - "), "\(console.id): \(console.system) is not a libretro name")
            #expect(ConsoleCatalog.coreName(console.core) == console.coreName)
            #expect(!console.extensions.isEmpty, "\(console.id) lists no file type")
            #expect(console.cores.first == console.core, "\(console.id): the recommended core comes first")
        }
        #expect(Set(ConsoleCatalog.all.map(\.id)).count == ConsoleCatalog.all.count)
    }

    @Test func theLibretroNamesAreTheDatabaseAndThumbnailFolders() {
        #expect(ConsoleCatalog.console("snes")?.system == "Nintendo - Super Nintendo Entertainment System")
        #expect(ConsoleCatalog.console("ps1")?.system == "Sony - PlayStation")
        #expect(ConsoleCatalog.console("gb")?.system == "Nintendo - Game Boy")
        #expect(ConsoleCatalog.console("genesis")?.system == "Sega - Mega Drive - Genesis")
    }

    @Test func glyphsFollowWhatTheGamesComeOn() {
        #expect(ConsoleCatalog.console("ps1")?.glyph == .disc)
        #expect(ConsoleCatalog.console("ps1")?.isDisc == true)
        #expect(ConsoleCatalog.console("gba")?.glyph == .handheld)
        #expect(ConsoleCatalog.console("snes")?.glyph == .cartridge)
    }

    @Test func biosNeedsAreThePlayStationsOnly() {
        let needing = ConsoleCatalog.all.filter { $0.bios != .none }.map(\.id)
        #expect(needing == ["ps1"])
        #expect(ConsoleCatalog.console("ps1")?.bios == .oneOf(["scph5501.bin", "scph5500.bin", "scph5502.bin"]))
    }

    @Test func extensionsFindTheirConsoles() {
        #expect(ConsoleCatalog.consoles(forExtension: "SFC").map(\.id) == ["snes"])
        #expect(ConsoleCatalog.consoles(forExtension: "gba").map(\.id) == ["gba"])
        #expect(ConsoleCatalog.consoles(forExtension: "cue").map(\.id) == ["ps1"])
        // A .bin is a Genesis or an Atari 2600 cartridge; the database decides
        #expect(ConsoleCatalog.consoles(forExtension: "bin").map(\.id) == ["genesis", "atari2600"])
        #expect(ConsoleCatalog.consoles(forExtension: "exe").isEmpty)
        #expect(ConsoleCatalog.extensions.contains("m3u"))
    }

    @Test func makersGroupTheSheet() {
        let grouped = ConsoleMaker.allCases.flatMap { ConsoleCatalog.made(by: $0) }
        #expect(Set(grouped.map(\.id)) == Set(ConsoleCatalog.all.map(\.id)))
        #expect(ConsoleCatalog.made(by: .sony).map(\.id) == ["ps1"])
    }

    @Test func coreNamesAreShownAsTheirProjectsWriteThem() {
        #expect(ConsoleCatalog.coreName("snes9x") == "Snes9x")
        #expect(ConsoleCatalog.coreName("mupen64plus_next") == "Mupen64Plus-Next")
        #expect(ConsoleCatalog.coreName("pcsx_rearmed") == "PCSX ReARMed")
        #expect(ConsoleCatalog.coreName("unknown_core") == "unknown_core")
    }

    @Test func theAddedSetIsKeptInCartouchesFolder() async throws {
        let work = try scratchFolder("shelf")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = RetroArchPaths(root: work)
        let shelf = ConsoleShelf(paths: paths, cores: CoreManager(paths: paths))
        #expect(await shelf.added().isEmpty)
        try JSONEncoder().encode(["gb", "nes"]).write(to: paths.consoles)
        // Catalog order, whatever the file's
        #expect(await shelf.added().map(\.id) == ["nes", "gb"])
    }
}
