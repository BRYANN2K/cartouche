import Foundation

// A console Cartouche can add, and the libretro core it plays with
public struct Console: Sendable, Identifiable, Equatable {
    public let id: String
    // Product names, shown as they are in every language
    public let name: String
    public let core: String
    public let bios: BIOSRule

    public init(id: String, name: String, core: String, bios: BIOSRule = .none) {
        self.id = id
        self.name = name
        self.core = core
        self.bios = bios
    }

    public var coreFile: String { "\(core)_libretro.dylib" }
}

// Which BIOS files a console needs before its games start. The core's .info
// file gives their MD5; it lists every file it can use, and marks none as
// needed even where the console cannot start without one.
public enum BIOSRule: Sendable, Equatable {
    case none
    // Any one of these; the first is the one named when all are missing
    case oneOf([String])
}

public enum ConsoleCatalog {
    // The recommended core per console: GPL or permissive where one plays
    // well, from docs/research/bonus-emulators.md
    public static let all: [Console] = [
        Console(id: "nes", name: "Nintendo Entertainment System", core: "nestopia"),
        Console(id: "snes", name: "Super Nintendo", core: "snes9x"),
        Console(id: "n64", name: "Nintendo 64", core: "mupen64plus_next"),
        Console(id: "gb", name: "Game Boy", core: "sameboy"),
        Console(id: "gbc", name: "Game Boy Color", core: "sameboy"),
        Console(id: "gba", name: "Game Boy Advance", core: "mgba"),
        Console(id: "nds", name: "Nintendo DS", core: "melonds"),
        Console(id: "genesis", name: "Sega Genesis", core: "genesis_plus_gx"),
        Console(id: "mastersystem", name: "Sega Master System", core: "genesis_plus_gx"),
        Console(id: "gamegear", name: "Sega Game Gear", core: "genesis_plus_gx"),
        Console(id: "pce", name: "PC Engine", core: "mednafen_pce_fast"),
        Console(
            id: "ps1", name: "PlayStation", core: "swanstation",
            bios: .oneOf(["scph5501.bin", "scph5500.bin", "scph5502.bin"])),
        Console(id: "atari2600", name: "Atari 2600", core: "stella"),
    ]

    public static func console(_ id: String) -> Console? { all.first { $0.id == id } }
}
