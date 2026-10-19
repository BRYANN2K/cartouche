// What the user chose in a game's Controls, kept in controls.json in Cartouche's
// folder, and the files each kind of game reads it from at launch.

import Foundation
import RetroArchKit

// The Wine Mac driver's options (dlls/winemac.drv/macdrv_main.c). The defaults are Wine's own.
struct KeyboardOptions: Codable, Equatable, Sendable {
    var commandAsControl = false
    var optionAsAlt = false
    // UseConfinementCursorClipping: macOS confines the pointer when the game clips it
    var keepMouseInside = true
    var preciseScrolling = true

    // Registry values for HKCU\Software\Wine\Mac Driver, always all of them, so
    // turning one back off undoes what an earlier launch imported
    var registryValues: [(name: String, on: Bool)] {
        [("LeftCommandIsCtrl", commandAsControl), ("RightCommandIsCtrl", commandAsControl),
         ("LeftOptionIsAlt", optionAsAlt), ("RightOptionIsAlt", optionAsAlt),
         ("UseConfinementCursorClipping", keepMouseInside), ("UsePreciseScrolling", preciseScrolling)]
    }

    var registryLines: [String] {
        registryValues.map { "\"\($0.name)\"=\"\($0.on ? "y" : "n")\"" }
    }

    // A .reg file `wine reg import` takes, with Windows line ends
    var registryFile: String {
        (["Windows Registry Editor Version 5.00", "", #"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#]
            + registryLines + [""]).joined(separator: "\r\n") + "\r\n"
    }
}

struct GameControls: Codable, Equatable, Sendable {
    var layout = ControllerLayout()
    var keyboard = KeyboardOptions()
    // Set once the user changed a keyboard option, from then on written at each change
    var keyboardSet = false
    var remapKeys = false
    var keyRemaps: [KeyRemap] = []
    var playWithController = false
}

// Which part of Cartouche handles a game's layout
enum ControlsHandler: Equatable, Sendable {
    // Steam games: Steam Input, configured in Steam
    case steamInput
    // Windows games Cartouche starts: an SDL mapping in the launch environment
    case cartouche
    // Console games: a RetroArch remap file
    case retroArch

    init(_ game: Game) {
        if game.console != nil || game.source.isConsole {
            self = .retroArch
        } else if game.source == .steam {
            self = .steamInput
        } else {
            self = .cartouche
        }
    }

    var title: String {
        switch self {
        case .steamInput: "Steam Input"
        case .cartouche: "Cartouche"
        case .retroArch: "RetroArch"
        }
    }

    var hint: String {
        switch self {
        case .steamInput: String(localized: "Layouts come from Steam Input.")
        case .cartouche: String(localized: "Keyboard, mouse and controller.")
        case .retroArch: String(localized: "Layouts are saved for RetroArch.")
        }
    }
}

actor ControlsStore {

    let file: URL
    private var cached: [String: GameControls]?

    init(folder: URL = SupportPaths.support) {
        file = folder.appending(path: "controls.json")
    }

    func all() -> [String: GameControls] {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: GameControls].self, from: $0) } ?? [:]
        cached = loaded
        return loaded
    }

    func controls(_ id: String) -> GameControls { all()[id] ?? GameControls() }

    func set(_ controls: GameControls, for id: String) throws {
        var table = all()
        table[id] = controls == GameControls() ? nil : controls
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicReplace(file, with: try encoder.encode(table), step: String(localized: "Save the game’s controls"))
        cached = table
    }
}

// The files a launch reads
struct ControlsFiles: Sendable {
    // Where Windows installer games live, one folder each
    var installs: URL = GameFolder.installs
    // setups/<appid>.keyboard for Steam games, beside the .env the run script reads
    var setups: URL = SupportPaths.setups
    var retroArch: RetroArchPaths

    func folder(of game: Game) -> GameFolder? {
        guard game.source == .installer, game.id.hasPrefix("installer:") else { return nil }
        return GameFolder(root: installs.appending(path: String(game.id.dropFirst("installer:".count))))
    }

    func apply(_ controls: GameControls, to game: Game) throws {
        switch ControlsHandler(game) {
        case .retroArch:
            if let console = game.console { try RetroArchRemap.apply(controls.layout, game: console, paths: retroArch) }
        case .steamInput:
            // Steam Input owns the layout; only the Mac driver keys are Cartouche's
            if controls.keyboardSet, let appID = game.steamAppID {
                let lines = controls.keyboard.registryLines.joined(separator: "\n") + "\n"
                try atomicReplace(setups.appending(path: "\(appID).keyboard"), with: Data(lines.utf8),
                                  step: String(localized: "Save the game’s controls"))
            }
        case .cartouche:
            guard let folder = folder(of: game) else { return }
            let sdl = folder.controllerMapping
            if let config = SDLMapping.config(controls.layout) {
                try atomicReplace(sdl, with: Data((config + "\n").utf8), step: String(localized: "Save the controller layout"))
            } else {
                try? FileManager.default.removeItem(at: sdl)
            }
            if controls.keyboardSet {
                try atomicReplace(folder.keyboardSettings, with: Data(controls.keyboard.registryFile.utf8),
                                  step: String(localized: "Save the game’s controls"))
            }
            try GameLauncher.addControls(to: folder)
        }
    }
}

extension GameFolder {
    // SDL_GAMECONTROLLERCONFIG lines, read by the launcher
    var controllerMapping: URL { root.appending(path: "controller.sdl") }
    // The Mac driver keys, imported into the prefix when they change
    var keyboardSettings: URL { root.appending(path: "keyboard.reg") }
    var keyboardApplied: URL { root.appending(path: ".keyboard.applied") }
}

extension GameLauncher {

    static let controlsMarker = "# Controls from Cartouche"

    // The launcher's lines that read the Controls files. A layout goes in the
    // environment; changed keyboard options are imported once, before the game.
    static func controlsBlock(folder: GameFolder) -> [String] {
        let sdl = quote(folder.controllerMapping.path(percentEncoded: false))
        let reg = quote(folder.keyboardSettings.path(percentEncoded: false))
        let applied = quote(folder.keyboardApplied.path(percentEncoded: false))
        return [
            controlsMarker,
            "if [ -f \(sdl) ]; then",
            "  SDL_GAMECONTROLLERCONFIG=$(cat \(sdl)); export SDL_GAMECONTROLLERCONFIG",
            "fi",
            "if [ -f \(reg) ] && ! cmp -s \(reg) \(applied); then",
            "  cp \(reg) \"$WINEPREFIX/drive_c/cartouche-keyboard.reg\" \\",
            "    && \"$WINELOADER\" reg import 'C:\\cartouche-keyboard.reg' >/dev/null 2>&1 \\",
            "    && cp \(reg) \(applied)",
            "  rm -f \"$WINEPREFIX/drive_c/cartouche-keyboard.reg\"",
            "fi",
        ]
    }

    // A launcher written before Controls existed gets the block, right before it starts the game
    static func addControls(to folder: GameFolder) throws {
        let url = folder.launcher
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.contains(controlsMarker) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.hasPrefix("cd ") || $0.hasPrefix("exec ") }) else { return }
        lines.insert(contentsOf: controlsBlock(folder: folder), at: at)
        try atomicReplace(url, with: Data(lines.joined(separator: "\n").utf8), step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}
