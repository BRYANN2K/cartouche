import Foundation

// An emulator the user installed; Cartouche never ships, fetches or configures one.
public struct StandaloneEmulator: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let bundleIDs: [String]
    public let appNames: [String]
    public let executableName: String
    public let consoles: [String]
    // The command line after the executable; %ROM% is the game file
    public let arguments: [String]
    // The emulator's own settings folder under ~, read and written only by it
    public let settings: String

    public static let rom = "%ROM%"

    public func arguments(for file: URL) -> [String] {
        arguments.map { $0 == Self.rom ? file.path(percentEncoded: false) : $0 }
    }
}

// Values cited in docs/research/standalone-emulators.md; no argument overrides the user's own settings.
public enum EmulatorCatalog {
    private static let rom = StandaloneEmulator.rom

    public static let all: [StandaloneEmulator] = [
        // -b "Run Dolphin without the user interface", -e "Load the specified file"; with -b Dolphin exits when the game stops.
        StandaloneEmulator(
            id: "dolphin", name: "Dolphin", bundleIDs: ["org.dolphin-emu.dolphin"], appNames: ["Dolphin"],
            executableName: "Dolphin", consoles: ["gamecube", "wii"], arguments: ["-b", "-e", rom],
            settings: "Library/Application Support/Dolphin"),
        // -batch "exits after shutting down", -- "the remaining parameters make up the filename".
        StandaloneEmulator(
            id: "pcsx2", name: "PCSX2", bundleIDs: ["net.pcsx2.pcsx2"], appNames: ["PCSX2"],
            executableName: "PCSX2", consoles: ["ps2"], arguments: ["-batch", "--", rom],
            settings: "Library/Application Support/PCSX2"),
        // macOS release is the SDL app (PPSSPPSDL); first file argument boots, --pause-menu-exit turns "Exit to menu" into "Exit".
        StandaloneEmulator(
            id: "ppsspp", name: "PPSSPP", bundleIDs: ["org.ppsspp.ppsspp"], appNames: ["PPSSPPSDL", "PPSSPP"],
            executableName: "PPSSPPSDL", consoles: ["psp"], arguments: ["--pause-menu-exit", rom],
            settings: ".config/ppsspp"),
        // src/citra_meta/common_strings.h: "Usage: {} [options] <file path>"
        StandaloneEmulator(
            id: "azahar", name: "Azahar", bundleIDs: ["org.azahar-emu.azahar"], appNames: ["Azahar"],
            executableName: "azahar", consoles: ["3ds"], arguments: [rom],
            settings: "Library/Application Support/Azahar"),
        // -dvd_path overrides the disc of xemu.toml for this run; closing the window powers off and exits.
        StandaloneEmulator(
            id: "xemu", name: "xemu", bundleIDs: ["xemu.app.0"], appNames: ["xemu"],
            executableName: "xemu", consoles: ["xbox"], arguments: ["-dvd_path", rom],
            settings: "Library/Application Support/xemu/xemu"),
        // The Ryujinx fork; the game is the last argument, as Ryujinx always took it.
        StandaloneEmulator(
            id: "ryubing", name: "Ryubing", bundleIDs: ["org.ryujinx.Ryujinx"], appNames: ["Ryujinx", "Ryubing"],
            executableName: "Ryujinx", consoles: ["switch"], arguments: [rom],
            settings: "Library/Application Support/Ryujinx"),
    ]

    public static func emulator(_ id: String) -> StandaloneEmulator? { all.first { $0.id == id } }

    public static func emulators(for console: String) -> [StandaloneEmulator] {
        all.filter { $0.consoles.contains(console) }
    }

    public static var names: String {
        all.map(\.name).formatted(.list(type: .and))
    }
}
