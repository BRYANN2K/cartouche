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
    // Loads name.state.auto with the game: Resume
    public var autoLoadState = false
    // Run-ahead, one frame: the panel's Lower input lag
    public var runAhead = false
    // RetroAchievements' hardcore mode, which forbids states and rewind
    public var hardcore = false
    // Play Together: the name the other players see, and whether a hosted
    // game is listed in libretro's lobby, played through its relay
    public var netplayNickname: String?
    public var netplayAnnounce = false
    // RetroAchievements: the account RetroArch signs in with, by token
    public var achievements: AchievementsLogin?
    // Translate the screen: RetroArch's AI service with the user's service
    public var translation: TranslationSetup?
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
            ("savestate_auto_load", autoLoadState ? "true" : "false"),
            ("savestate_thumbnail_enable", "true"),
            ("video_fullscreen", fullscreen ? "true" : "false"),
            ("network_cmd_enable", networkCommands ? "true" : "false"),
            ("network_cmd_port", String(networkCommandPort)),
            ("video_shader_dir", path(paths.shaders)),
            ("run_ahead_enabled", runAhead ? "true" : "false"),
            ("run_ahead_frames", "1"),
            // One instance: a second copy of the core does not follow a loaded state
            ("run_ahead_secondary_instance", "false"),
            ("cheevos_hardcore_mode_enable", hardcore ? "true" : "false"),
            // The UDP commands answer this Mac only
            ("network_cmd_bind_address", "127.0.0.1"),
            ("netplay_public_announce", netplayAnnounce ? "true" : "false"),
            ("netplay_use_mitm_server", netplayAnnounce ? "true" : "false"),
        ]
        if hardcore { values.append(("rewind_enable", "false")) }
        if let netplayNickname { values.append(("netplay_nickname", netplayNickname)) }
        values += achievementValues + translationValues
        for key in extra.keys.sorted() {
            values.removeAll { $0.0 == key }
            values.append((key, extra[key]!))
        }
        return values
    }

    // The token is the only secret; a password is never written
    private var achievementValues: [(String, String)] {
        guard let login = achievements else {
            return [("cheevos_enable", "false"), ("cheevos_username", ""), ("cheevos_token", ""), ("cheevos_password", "")]
        }
        return [
            ("cheevos_enable", "true"),
            ("cheevos_username", login.username),
            ("cheevos_token", login.token),
            ("cheevos_password", ""),
            ("cheevos_custom_host", login.host?.absoluteString ?? ""),
            // The log is how Cartouche learns which game RetroAchievements recognized
            ("cheevos_verbose_enable", "true"),
            ("log_verbosity", "true"),
        ]
    }

    private var translationValues: [(String, String)] {
        guard let translation else { return [("ai_service_enable", "false")] }
        return [
            ("ai_service_enable", "true"),
            ("ai_service_url", translation.service.absoluteString),
            // Image mode: the translation is drawn over the game
            ("ai_service_mode", "0"),
            ("ai_service_target_lang", String(translation.targetLanguage)),
            ("ai_service_pause", "true"),
        ]
    }

    // The same configuration with the token taken out, written again once
    // RetroArch has read it, so the token does not stay on disk
    public var withoutSecrets: AppendConfig {
        var copy = self
        copy.achievements?.token = ""
        return copy
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
        // It holds the RetroAchievements token while RetroArch starts
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.appendConfig.path(percentEncoded: false))
    }
}
