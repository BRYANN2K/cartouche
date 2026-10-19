import Foundation

// cartouche.cfg, which RetroArch reads after its own retroarch.cfg through
// --appendconfig. Its values win over the user's, and it is the only
// configuration Cartouche writes.
public struct AppendConfig: Sendable, Equatable {

    public enum Problem: Error, Equatable {
        case unwritableValue(key: String)
    }

    public var paths: RetroArchPaths
    public var autoSaveState = true
    // The UDP commands, for builds that have no MCP server
    public var networkCommands = false
    // Not RetroArch's 55355, where the user's own RetroArch may listen: a QUIT
    // sent there would close it
    public var networkCommandPort: UInt16 = 55455
    public var fullscreen = false
    // For tests and diagnostics: drivers, logging
    public var extra: [String: String] = [:]

    public init(paths: RetroArchPaths) { self.paths = paths }

    public var values: [(String, String)] {
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        var values: [(String, String)] = [
            // RetroArch would otherwise write the merged settings, ours
            // included, back into its retroarch.cfg when it quits
            ("config_save_on_exit", "false"),
            ("confirm_quit", "false"),
            ("libretro_directory", path(paths.cores)),
            ("libretro_info_path", path(paths.coreInfo)),
            ("system_directory", path(paths.bios)),
            ("savefile_directory", path(paths.saves)),
            ("savestate_directory", path(paths.states)),
            ("screenshot_directory", path(paths.screenshots)),
            // Folders RetroArch would otherwise share with the user's own
            // RetroArch, in ~/Documents/RetroArch and ~/Library/Application Support
            ("playlist_directory", path(paths.playlists)),
            ("log_dir", path(paths.logs)),
            ("recording_output_directory", path(paths.recordings)),
            ("recording_config_directory", path(paths.recordings)),
            ("thumbnails_directory", path(paths.thumbnails)),
            ("cache_directory", path(paths.cache)),
            ("rgui_config_directory", path(paths.menuConfig)),
            ("input_remapping_directory", path(paths.menuConfig.appending(path: "remaps", directoryHint: .isDirectory))),
            ("bundle_assets_dst_path", path(paths.bundle)),
            ("assets_directory", path(paths.bundle.appending(path: "assets", directoryHint: .isDirectory))),
            ("overlay_directory", path(paths.bundle.appending(path: "overlays", directoryHint: .isDirectory))),
            ("savestate_auto_save", autoSaveState ? "true" : "false"),
            ("savestate_auto_load", "false"),
            ("savestate_thumbnail_enable", "true"),
            ("video_fullscreen", fullscreen ? "true" : "false"),
            ("network_cmd_enable", networkCommands ? "true" : "false"),
            ("network_cmd_port", String(networkCommandPort)),
        ]
        for key in extra.keys.sorted() {
            values.removeAll { $0.0 == key }
            values.append((key, extra[key]!))
        }
        return values
    }

    public func render() throws -> String {
        var text = "# Written by Cartouche before each launch. Your retroarch.cfg is not changed.\n"
        for (key, value) in values {
            // The format has no escape for a quote or a line break
            guard !value.contains("\""), !value.contains("\n"), !value.contains("\r") else {
                throw Problem.unwritableValue(key: key)
            }
            text += "\(key) = \"\(value)\"\n"
        }
        return text
    }

    public func write() throws {
        try paths.create()
        try Data(render().utf8).write(to: paths.appendConfig, options: .atomic)
    }
}
