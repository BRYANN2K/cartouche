// RetroArch loads <input_remapping_directory>/<core name>/<content name>.rmp when the game starts (config_load_remap); the folder is the one cartouche.cfg names.

import Foundation
import RetroArchKit

enum RetroArchRemap {

    // Marks the files Cartouche wrote; one the user saved from RetroArch's menu is left alone
    static let header = "# Written by Cartouche for this game's controller layout."

    static func folder(_ paths: RetroArchPaths) -> URL {
        paths.menuConfig.appending(path: "remaps", directoryHint: .isDirectory)
    }

    // RetroArch names the folder after the core's library_name, which the catalog keeps
    static func file(core: String, content: String, paths: RetroArchPaths) -> URL {
        folder(paths).appending(path: ConsoleCatalog.coreName(core), directoryHint: .isDirectory)
            .appending(path: "\(content).rmp")
    }

    // RetroArch's key names in remap files and the RetroPad ids (libretro.h, RETRO_DEVICE_ID_JOYPAD_*)
    static func key(_ button: PadButton) -> (name: String, id: Int) {
        switch button {
        case .south: ("b", 0)
        case .west: ("y", 1)
        case .back: ("select", 2)
        case .start: ("start", 3)
        case .up: ("up", 4)
        case .down: ("down", 5)
        case .left: ("left", 6)
        case .right: ("right", 7)
        case .east: ("a", 8)
        case .north: ("x", 9)
        case .leftShoulder: ("l", 10)
        case .rightShoulder: ("r", 11)
        case .leftTrigger: ("l2", 12)
        case .rightTrigger: ("r2", 13)
        case .leftStick: ("l3", 14)
        case .rightStick: ("r3", 15)
        }
    }

    // input_player1_btn_<pressed> = "<what the core gets>", for player 1's RetroPad
    static func render(_ layout: ControllerLayout) -> String {
        var lines = [header, #"input_libretro_device_p1 = "1""#, #"input_remap_port_p1 = "0""#]
        for button in PadButton.allCases.sorted(by: { key($0).id < key($1).id }) {
            lines.append(#"input_player1_btn_\#(key(button).name) = "\#(key(layout.target(of: button)).id)""#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func isOurs(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.hasPrefix(header)
    }

    // Writes the file for each core that can play the game, so a core picked later finds it too. The standard layout removes the files Cartouche wrote.
    static func apply(_ layout: ControllerLayout, game: ConsoleGame, paths: RetroArchPaths) throws {
        var cores = ConsoleCatalog.console(game.console)?.cores ?? []
        if let chosen = game.setup.core, !cores.contains(chosen) { cores.append(chosen) }
        for core in cores {
            try apply(layout, core: core, content: game.contentName, paths: paths)
        }
    }

    static func apply(_ layout: ControllerLayout, core: String, content: String, paths: RetroArchPaths) throws {
        let url = file(core: core, content: content, paths: paths)
        let fm = FileManager.default
        if layout.isStandard {
            if isOurs(url) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(url, with: Data(render(layout).utf8), step: String(localized: "Save the controller layout"))
    }
}
