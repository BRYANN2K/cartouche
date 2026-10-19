import Foundation

// An emulator the user installed on their own. Cartouche finds it and starts
// games with it; it never ships, fetches or configures one.
public struct StandaloneEmulator: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    // The product name, as the project writes it
    public let name: String
    // CFBundleIdentifier of the app as the project builds it
    public let bundleIDs: [String]
    // The app's name in Applications, for a build with another identifier
    public let appNames: [String]
    // CFBundleExecutable as the project ships it
    public let executableName: String
    // Ids from ConsoleCatalog
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

// The six standalone emulators of docs/research/standalone-emulators.md, which
// cites each value. The game starts with the user's own settings: no argument
// forces full screen or any other option.
public enum EmulatorCatalog {
    private static let rom = StandaloneEmulator.rom

    public static let all: [StandaloneEmulator] = [
        // Source/Core/UICommon/CommandLineParse.cpp: -b "Run Dolphin without the
        // user interface", -e "Load the specified file". With -b, Dolphin exits
        // when the game stops (DolphinQt/MainWindow.cpp, OnStopComplete).
        StandaloneEmulator(
            id: "dolphin", name: "Dolphin", bundleIDs: ["org.dolphin-emu.dolphin"], appNames: ["Dolphin"],
            executableName: "Dolphin", consoles: ["gamecube", "wii"], arguments: ["-b", "-e", rom],
            settings: "Library/Application Support/Dolphin"),
        // pcsx2-qt/QtHost.cpp: -batch "exits after shutting down", -- "the
        // remaining parameters make up the filename"
        StandaloneEmulator(
            id: "pcsx2", name: "PCSX2", bundleIDs: ["net.pcsx2.pcsx2"], appNames: ["PCSX2"],
            executableName: "PCSX2", consoles: ["ps2"], arguments: ["-batch", "--", rom],
            settings: "Library/Application Support/PCSX2"),
        // The macOS release is the SDL app (CMakeLists.txt: PPSSPPSDL). The first
        // file argument boots (UI/NativeApp.cpp); --pause-menu-exit turns "Exit
        // to menu" into "Exit" (ppsspp.org command-line reference).
        StandaloneEmulator(
            id: "ppsspp", name: "PPSSPP", bundleIDs: ["org.ppsspp.ppsspp"], appNames: ["PPSSPPSDL", "PPSSPP"],
            executableName: "PPSSPPSDL", consoles: ["psp"], arguments: ["--pause-menu-exit", rom],
            settings: ".config/ppsspp"),
        // src/citra_meta/common_strings.h: "Usage: {} [options] <file path>"
        StandaloneEmulator(
            id: "azahar", name: "Azahar", bundleIDs: ["org.azahar-emu.azahar"], appNames: ["Azahar"],
            executableName: "azahar", consoles: ["3ds"], arguments: [rom],
            settings: "Library/Application Support/Azahar"),
        // system/vl.c: -dvd_path overrides the disc of xemu.toml for this run;
        // closing the window powers off and exits (ui/xemu.c)
        StandaloneEmulator(
            id: "xemu", name: "xemu", bundleIDs: ["xemu.app.0"], appNames: ["xemu"],
            executableName: "xemu", consoles: ["xbox"], arguments: ["-dvd_path", rom],
            settings: "Library/Application Support/xemu/xemu"),
        // The Ryujinx fork. Its setup guide names Ryujinx.app/Contents/MacOS/Ryujinx;
        // the game is the last argument, as Ryujinx always took it
        StandaloneEmulator(
            id: "ryubing", name: "Ryubing", bundleIDs: ["org.ryujinx.Ryujinx"], appNames: ["Ryujinx", "Ryubing"],
            executableName: "Ryujinx", consoles: ["switch"], arguments: [rom],
            settings: "Library/Application Support/Ryujinx"),
    ]

    public static func emulator(_ id: String) -> StandaloneEmulator? { all.first { $0.id == id } }

    // The emulators that play a console, in catalog order
    public static func emulators(for console: String) -> [StandaloneEmulator] {
        all.filter { $0.consoles.contains(console) }
    }

    // "Dolphin, PCSX2, PPSSPP, Azahar, xemu and Ryubing"
    public static var names: String {
        all.map(\.name).formatted(.list(type: .and))
    }
}
