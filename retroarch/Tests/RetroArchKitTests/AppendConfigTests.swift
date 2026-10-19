import Foundation
import Testing

@testable import RetroArchKit

@Suite("Appended configuration")
struct AppendConfigTests {

    private let paths = RetroArchPaths(root: URL(fileURLWithPath: "/tmp/cartouche-ra"))

    private func value(_ key: String, in config: AppendConfig) -> String? {
        config.values.first { $0.0 == key }?.1
    }

    @Test func neverLetsRetroArchSaveOverTheUsersConfig() {
        #expect(value("config_save_on_exit", in: AppendConfig(paths: paths)) == "false")
    }

    @Test func pointsRetroArchAtCartouchesFolders() {
        let config = AppendConfig(paths: paths)
        #expect(value("libretro_directory", in: config) == "/tmp/cartouche-ra/cores/")
        #expect(value("system_directory", in: config) == "/tmp/cartouche-ra/system/")
        #expect(value("savestate_directory", in: config) == "/tmp/cartouche-ra/states/")
        #expect(value("libretro_info_path", in: config) == "/tmp/cartouche-ra/info/")
    }

    @Test func quitsOnOnePress() {
        // QUIT and a closed pipe would otherwise only ask "press again to quit"
        #expect(value("confirm_quit", in: AppendConfig(paths: paths)) == "false")
    }

    @Test func autoSaveStateAndNetworkCommandsFollowTheChoice() {
        var config = AppendConfig(paths: paths)
        #expect(value("savestate_auto_save", in: config) == "true")
        #expect(value("network_cmd_enable", in: config) == "false")
        config.autoSaveState = false
        config.networkCommands = true
        #expect(value("savestate_auto_save", in: config) == "false")
        #expect(value("network_cmd_enable", in: config) == "true")
    }

    @Test func extraValuesReplaceDefaultsOnce() throws {
        var config = AppendConfig(paths: paths)
        config.extra = ["video_fullscreen": "true", "video_driver": "null"]
        let text = try config.render()
        #expect(text.components(separatedBy: "video_fullscreen").count == 2)
        #expect(text.contains("video_driver = \"null\"\n"))
    }

    @Test func refusesAValueTheFormatCannotHold() {
        let config = AppendConfig(paths: RetroArchPaths(root: URL(fileURLWithPath: "/tmp/a\"b")))
        #expect(throws: AppendConfig.Problem.self) { try config.render() }
    }

    @Test func writesOnlyItsOwnFile() throws {
        let work = try scratchFolder("append")
        defer { try? FileManager.default.removeItem(at: work) }
        let config = AppendConfig(paths: RetroArchPaths(root: work))
        try config.write()
        let written = try String(contentsOf: work.appending(path: "cartouche.cfg"), encoding: .utf8)
        #expect(written == (try config.render()))
        let files = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { !$0.hasSuffix("/") }
        #expect(!files.contains("retroarch.cfg"))
    }
}
