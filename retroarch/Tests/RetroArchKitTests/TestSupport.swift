import Foundation
import Testing

@testable import RetroArchKit

// Everything a test writes goes under the temporary folder, never ~/Library
func scratchFolder(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "rak-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class Marker {}

enum Fixtures {
    static var folder: URL {
        Bundle.module.resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    static func url(_ name: String) -> URL { folder.appending(path: name) }

    static var pinnedToolsList: URL { url("tools-list-ed3187e.json") }

    static func pinnedTools() throws -> [MCPTool] {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: pinnedToolsList))
        return (json["tools"]?.array ?? []).compactMap(MCPTool.init)
    }

    // Built beside the test bundle, as a dependency of the test target
    static var fakeRetroArch: URL {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "fake-retroarch")
    }
}

// The real RetroArch and the test core, when the environment names them
// (make retroarch-rig retroarch-testcore, then the paths it prints)
enum Rig {
    static var retroarch: URL? {
        ProcessInfo.processInfo.environment["CARTOUCHE_RETROARCH"].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    static var testCore: URL? {
        ProcessInfo.processInfo.environment["CARTOUCHE_TEST_CORE"].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static var network: Bool { ProcessInfo.processInfo.environment["CARTOUCHE_NETWORK_TESTS"] == "1" }

    static var hasRetroArch: Bool { retroarch != nil }
    static var hasRetroArchAndCore: Bool { retroarch != nil && testCore != nil }

    // The video driver for a window, or none on a machine without a display
    static var video: String { ProcessInfo.processInfo.environment["CARTOUCHE_RETROARCH_VIDEO"] ?? "null" }

    // A home in the scratch folder: RetroArch makes its default folders, and
    // looks for the user's retroarch.cfg, under it
    static func home(_ folder: URL) -> URL { folder.appending(path: "home", directoryHint: .isDirectory) }

    static func launch(
        _ config: AppendConfig, in folder: URL, baseConfig: RetroArchLaunch.BaseConfig = .cartouche
    ) -> RetroArchLaunch {
        var config = config
        // No sound, keyboard input (the null input driver crashes when the
        // pointer crosses RetroArch's window), and a window only when asked
        var drivers = [
            "video_driver": video, "audio_driver": "null", "input_driver": "cocoa",
            "menu_driver": "rgui", "pause_nonactive": "false",
        ]
        // With no video driver there is no picture to put in a state, and
        // RetroArch then fails the next command
        if video == "null" { drivers["savestate_thumbnail_enable"] = "false" }
        config.extra = drivers.merging(config.extra) { $1 }
        var launch = RetroArchLaunch(executable: retroarch!, config: config, baseConfig: baseConfig)
        launch.verbose = true
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home(folder).path(percentEncoded: false)
        // macOS RetroArch finds ~/Documents through Foundation, which reads
        // this rather than HOME; without it the default playlist folder is
        // made in the real ~/Documents/RetroArch before the config is read
        environment["CFFIXED_USER_HOME"] = home(folder).path(percentEncoded: false)
        launch.environment = environment
        return launch
    }

    // The user's own retroarch.cfg, where RetroArch looks for it, with the
    // choice that would make RetroArch rewrite it on exit
    static func userConfig(in folder: URL) throws -> URL {
        let url = home(folder).appending(path: "Library/Application Support/RetroArch/config/retroarch.cfg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # the user's own settings
        video_driver = "\(video)"
        audio_driver = "null"
        input_driver = "cocoa"
        menu_driver = "rgui"
        config_save_on_exit = "true"
        pause_nonactive = "false"
        input_player1_a = "x"
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
