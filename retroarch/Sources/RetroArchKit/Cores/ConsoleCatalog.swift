import Foundation

// The sidebar and Add Consoles glyph: what the console's games come on
public enum ConsoleGlyph: String, Sendable, CaseIterable {
    case cartridge, disc, handheld
}

// Who made it, the groups of the Add Consoles sheet
public enum ConsoleMaker: String, Sendable, CaseIterable {
    case nintendo, sega, sony, others

    // Company names; "Others" is the one word to translate
    public var title: String {
        switch self {
        case .nintendo: "Nintendo"
        case .sega: "Sega"
        case .sony: "Sony"
        case .others: String(localized: "Others", bundle: .module)
        }
    }
}

// A console Cartouche can add, and the libretro core it plays with
public struct Console: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    // Product names, shown as they are in every language
    public let name: String
    public let core: String
    public let bios: BIOSRule
    // The libretro database and libretro-thumbnails name the console this way
    public let system: String
    public let coreName: String
    public let glyph: ConsoleGlyph
    public let maker: ConsoleMaker
    // Lowercased, without the dot; a disc console lists its sheet formats
    public let extensions: [String]
    // Cores that also play it, recommended first
    public let cores: [String]

    public init(
        id: String, name: String, core: String, bios: BIOSRule = .none, system: String = "",
        coreName: String? = nil, glyph: ConsoleGlyph = .cartridge, maker: ConsoleMaker = .others,
        extensions: [String] = [], cores: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.core = core
        self.bios = bios
        self.system = system
        self.coreName = coreName ?? core
        self.glyph = glyph
        self.maker = maker
        self.extensions = extensions
        self.cores = cores ?? (core.isEmpty ? [] : [core])
    }

    public var coreFile: String { "\(core)_libretro.dylib" }

    // False for a console only a standalone emulator plays (P16)
    public var hasCore: Bool { !core.isEmpty }

    public var isDisc: Bool { glyph == .disc }
}

// Which BIOS files a console needs before its games start. The core's .info
// file gives their MD5; it lists every file it can use, and marks none as
// needed even where the console cannot start without one.
public enum BIOSRule: Sendable, Equatable, Hashable {
    case none
    // Any one of these; the first is the one named when all are missing
    case oneOf([String])
}

public enum ConsoleCatalog {
    // The recommended core per console: GPL or permissive where one plays
    // well, from docs/research/bonus-emulators.md
    public static let all: [Console] = [
        Console(id: "nes", name: "Nintendo Entertainment System", core: "nestopia",
                system: "Nintendo - Nintendo Entertainment System", coreName: "Nestopia",
                maker: .nintendo, extensions: ["nes"], cores: ["nestopia", "mesen", "fceumm"]),
        Console(id: "snes", name: "Super Nintendo", core: "snes9x",
                system: "Nintendo - Super Nintendo Entertainment System", coreName: "Snes9x",
                maker: .nintendo, extensions: ["sfc", "smc"], cores: ["snes9x", "bsnes", "mesen-s"]),
        Console(id: "n64", name: "Nintendo 64", core: "mupen64plus_next",
                system: "Nintendo - Nintendo 64", coreName: "Mupen64Plus-Next",
                maker: .nintendo, extensions: ["n64", "z64", "v64"], cores: ["mupen64plus_next", "parallel_n64"]),
        Console(id: "gb", name: "Game Boy", core: "sameboy",
                system: "Nintendo - Game Boy", coreName: "SameBoy",
                glyph: .handheld, maker: .nintendo, extensions: ["gb"], cores: ["sameboy", "gambatte"]),
        Console(id: "gbc", name: "Game Boy Color", core: "sameboy",
                system: "Nintendo - Game Boy Color", coreName: "SameBoy",
                glyph: .handheld, maker: .nintendo, extensions: ["gbc"], cores: ["sameboy", "gambatte"]),
        Console(id: "gba", name: "Game Boy Advance", core: "mgba",
                system: "Nintendo - Game Boy Advance", coreName: "mGBA",
                glyph: .handheld, maker: .nintendo, extensions: ["gba"], cores: ["mgba", "vbam"]),
        Console(id: "nds", name: "Nintendo DS", core: "melonds",
                system: "Nintendo - Nintendo DS", coreName: "melonDS",
                glyph: .handheld, maker: .nintendo, extensions: ["nds"], cores: ["melonds", "desmume"]),
        Console(id: "genesis", name: "Sega Genesis", core: "genesis_plus_gx",
                system: "Sega - Mega Drive - Genesis", coreName: "Genesis Plus GX",
                maker: .sega, extensions: ["md", "gen", "smd", "bin"], cores: ["genesis_plus_gx", "picodrive"]),
        Console(id: "mastersystem", name: "Sega Master System", core: "genesis_plus_gx",
                system: "Sega - Master System - Mark III", coreName: "Genesis Plus GX",
                maker: .sega, extensions: ["sms"], cores: ["genesis_plus_gx", "picodrive"]),
        Console(id: "gamegear", name: "Sega Game Gear", core: "genesis_plus_gx",
                system: "Sega - Game Gear", coreName: "Genesis Plus GX",
                glyph: .handheld, maker: .sega, extensions: ["gg"], cores: ["genesis_plus_gx"]),
        Console(id: "pce", name: "PC Engine", core: "mednafen_pce_fast",
                system: "NEC - PC Engine - TurboGrafx 16", coreName: "Beetle PCE Fast",
                maker: .others, extensions: ["pce"], cores: ["mednafen_pce_fast"]),
        Console(
            id: "ps1", name: "PlayStation", core: "swanstation",
            bios: .oneOf(["scph5501.bin", "scph5500.bin", "scph5502.bin"]),
            system: "Sony - PlayStation", coreName: "SwanStation",
            glyph: .disc, maker: .sony, extensions: ["cue", "chd", "m3u"],
            cores: ["swanstation", "mednafen_psx_hw", "pcsx_rearmed"]),
        Console(id: "atari2600", name: "Atari 2600", core: "stella",
                system: "Atari - 2600", coreName: "Stella",
                maker: .others, extensions: ["a26", "bin"], cores: ["stella"]),
        // Consoles a standalone emulator plays best (P16, EmulatorCatalog). The
        // core is the buildbot's for Apple silicon, where there is one.
        Console(id: "gamecube", name: "GameCube", core: "dolphin",
                system: "Nintendo - GameCube", coreName: "Dolphin", glyph: .disc, maker: .nintendo,
                extensions: ["iso", "gcm", "rvz", "gcz", "ciso", "wia", "tgc", "dol"]),
        Console(id: "wii", name: "Wii", core: "dolphin",
                system: "Nintendo - Wii", coreName: "Dolphin", glyph: .disc, maker: .nintendo,
                extensions: ["iso", "wbfs", "rvz", "gcz", "ciso", "wia", "wad"]),
        Console(id: "3ds", name: "Nintendo 3DS", core: "azahar",
                system: "Nintendo - Nintendo 3DS", coreName: "Azahar", glyph: .handheld, maker: .nintendo,
                extensions: ["3ds", "cci", "cxi", "3dsx", "z3dsx", "zcci", "zcxi"], cores: ["azahar", "citra"]),
        Console(id: "switch", name: "Nintendo Switch", core: "",
                system: "Nintendo - Nintendo Switch", glyph: .handheld, maker: .nintendo,
                extensions: ["nsp", "xci", "nro"]),
        // Play! needs no BIOS file
        Console(id: "ps2", name: "PlayStation 2", core: "play",
                system: "Sony - PlayStation 2", coreName: "Play!", glyph: .disc, maker: .sony,
                extensions: ["iso", "cso", "zso", "mdf"]),
        Console(id: "psp", name: "PlayStation Portable", core: "ppsspp",
                system: "Sony - PlayStation Portable", coreName: "PPSSPP", glyph: .handheld, maker: .sony,
                extensions: ["iso", "cso", "pbp"]),
        Console(id: "xbox", name: "Xbox", core: "",
                system: "Microsoft - Xbox", glyph: .disc, maker: .others,
                extensions: ["iso", "xiso"]),
    ]

    public static func console(_ id: String) -> Console? { all.first { $0.id == id } }

    // Every console whose games can come in a file with this extension
    public static func consoles(forExtension ext: String) -> [Console] {
        let ext = ext.lowercased()
        return all.filter { $0.extensions.contains(ext) }
    }

    // Every extension a console game file can have, for the folder scan
    public static var extensions: Set<String> { Set(all.flatMap(\.extensions)) }

    // The consoles of one maker, in catalog order
    public static func made(by maker: ConsoleMaker) -> [Console] { all.filter { $0.maker == maker } }

    // Display names of the other cores; a core not listed shows its file name
    public static func coreName(_ core: String) -> String {
        if let console = all.first(where: { $0.core == core }) { return console.coreName }
        return otherCoreNames[core] ?? core
    }

    static let otherCoreNames = [
        "mesen": "Mesen", "fceumm": "FCEUmm", "bsnes": "bsnes", "mesen-s": "Mesen-S",
        "parallel_n64": "ParaLLEl N64", "gambatte": "Gambatte", "vbam": "VBA-M", "desmume": "DeSmuME",
        "picodrive": "PicoDrive", "mednafen_psx_hw": "Beetle PSX HW", "pcsx_rearmed": "PCSX ReARMed",
        "citra": "Citra",
    ]
}
