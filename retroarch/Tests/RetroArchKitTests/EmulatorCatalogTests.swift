import Foundation
import Testing

@testable import RetroArchKit

// P16: the standalone emulator catalog and the consoles it plays
@Suite("Standalone emulator catalog")
struct EmulatorCatalogTests {

    @Test func everyEmulatorNamesItsAppArgumentsAndConsoles() {
        #expect(EmulatorCatalog.all.map(\.id) == ["dolphin", "pcsx2", "ppsspp", "azahar", "xemu", "ryubing"])
        for emulator in EmulatorCatalog.all {
            #expect(!emulator.bundleIDs.isEmpty && !emulator.appNames.isEmpty, "\(emulator.id) cannot be found")
            #expect(emulator.arguments.filter { $0 == StandaloneEmulator.rom }.count == 1, "\(emulator.id) does not pass the game once")
            #expect(!emulator.consoles.isEmpty)
            for console in emulator.consoles {
                #expect(ConsoleCatalog.console(console) != nil, "\(emulator.id) plays \(console), which is not in the console catalog")
            }
            #expect(emulator.settings.hasPrefix("Library/") || emulator.settings.hasPrefix("."), "\(emulator.id): \(emulator.settings)")
        }
    }

    @Test func eachEmulatorStartsTheGameWithItsDocumentedArguments() {
        let game = URL(fileURLWithPath: "/Games/My Game (Homebrew).iso")
        let path = game.path
        let expected: [String: [String]] = [
            // -b batch: no Dolphin menu; -e exec: the file to boot
            "dolphin": ["-b", "-e", path],
            "pcsx2": ["-batch", "--", path],
            "ppsspp": ["--pause-menu-exit", path],
            "azahar": [path],
            "xemu": ["-dvd_path", path],
            "ryubing": [path],
        ]
        for emulator in EmulatorCatalog.all {
            #expect(emulator.arguments(for: game) == expected[emulator.id], "\(emulator.id)")
        }
    }

    @Test func consolesFindTheirEmulators() {
        #expect(EmulatorCatalog.emulators(for: "gamecube").map(\.id) == ["dolphin"])
        #expect(EmulatorCatalog.emulators(for: "wii").map(\.id) == ["dolphin"])
        #expect(EmulatorCatalog.emulators(for: "ps2").map(\.id) == ["pcsx2"])
        #expect(EmulatorCatalog.emulators(for: "psp").map(\.id) == ["ppsspp"])
        #expect(EmulatorCatalog.emulators(for: "3ds").map(\.id) == ["azahar"])
        #expect(EmulatorCatalog.emulators(for: "xbox").map(\.id) == ["xemu"])
        #expect(EmulatorCatalog.emulators(for: "switch").map(\.id) == ["ryubing"])
        #expect(EmulatorCatalog.emulators(for: "snes").isEmpty)
        for name in ["Dolphin", "PCSX2", "PPSSPP", "Azahar", "xemu", "Ryubing"] {
            #expect(EmulatorCatalog.names.contains(name))
        }
    }

    // No download link and no word about where keys, firmware or BIOS come from
    @Test func noLinkToAnEmulatorFileOrKeys() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/RetroArchKit/Standalone").standardized
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for word in ["prod.keys", "title.keys", "firmware", "bios", "download", "rom site", "dump"] {
                #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
    }
}
