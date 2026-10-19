import Foundation
import RetroArchKit
import Testing

@testable import NotProtonApp

@Suite("Mac keyboard and mouse in Wine games", .serialized)
struct MacKeyboardTests {

    @Test("Command as Control sets both Command keys; every option is written, y or n")
    func registryFile() {
        var options = KeyboardOptions()
        options.commandAsControl = true
        #expect(options.registryLines == [
            #""LeftCommandIsCtrl"="y""#, #""RightCommandIsCtrl"="y""#,
            #""LeftOptionIsAlt"="n""#, #""RightOptionIsAlt"="n""#,
            #""UseConfinementCursorClipping"="y""#, #""UsePreciseScrolling"="y""#,
        ])
        let file = options.registryFile
        #expect(file.hasPrefix("Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n"))
        #expect(file.hasSuffix("\"UsePreciseScrolling\"=\"y\"\r\n\r\n"))
        #expect(!file.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("Wine's own defaults until the user changes an option, so nothing is written before")
    func defaults() throws {
        let fixture = try LauncherFixture("kbd-default")
        defer { fixture.remove() }
        #expect(KeyboardOptions() == KeyboardOptions(commandAsControl: false, optionAsAlt: false, keepMouseInside: true, preciseScrolling: true))
        try fixture.files.apply(GameControls(), to: fixture.game)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.keyboardSettings.path))
        try fixture.launch()
        #expect(fixture.calls.allSatisfy { !$0.hasPrefix("reg ") })
    }

    @Test("Command as Control for an installed game: imported into its prefix before the game, once per change")
    func installerGame() throws {
        let fixture = try LauncherFixture("kbd-installer")
        defer { fixture.remove() }
        var controls = GameControls()
        controls.keyboard.commandAsControl = true
        controls.keyboardSet = true
        try fixture.files.apply(controls, to: fixture.game)
        try fixture.launch()
        #expect(fixture.calls == [#"reg import C:\cartouche-keyboard.reg"#, "game " + fixture.game.executable!.path(percentEncoded: false)])
        let imported = try String(contentsOf: fixture.out.appending(path: "imported.reg"), encoding: .utf8)
        #expect(imported == controls.keyboard.registryFile)
        #expect(imported.contains(#""LeftCommandIsCtrl"="y""#))
        // The temporary copy in drive_c is gone
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.prefix.appending(path: "drive_c/cartouche-keyboard.reg").path))

        // Unchanged: no second import
        try fixture.launch()
        #expect(fixture.calls.filter { $0.hasPrefix("reg ") }.count == 1)

        // Turned back off: imported again, with n
        controls.keyboard.commandAsControl = false
        try fixture.files.apply(controls, to: fixture.game)
        try fixture.launch()
        #expect(fixture.calls.filter { $0.hasPrefix("reg ") }.count == 2)
        #expect(try String(contentsOf: fixture.out.appending(path: "imported.reg"), encoding: .utf8).contains(#""LeftCommandIsCtrl"="n""#))
    }

    @Test("A Steam game's options go beside its setup, where the run script reads them")
    func steamGame() throws {
        let work = try scratchDirectory("kbd-steam")
        defer { try? FileManager.default.removeItem(at: work) }
        let files = ControlsFiles(installs: work.appending(path: "installs"), setups: work.appending(path: "setups"),
                                  retroArch: RetroArchPaths(root: work.appending(path: "retroarch")))
        let game = Game.steam(1_145_360, name: "Hades", installed: true)
        var controls = GameControls()
        try files.apply(controls, to: game)
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "setups/1145360.keyboard").path))
        controls.keyboard.optionAsAlt = true
        controls.keyboardSet = true
        // A layout for a Steam game is Steam Input's: no SDL file anywhere
        controls.layout = .preset(.swapAB)
        try files.apply(controls, to: game)
        let text = try String(contentsOf: work.appending(path: "setups/1145360.keyboard"), encoding: .utf8)
        #expect(text == controls.keyboard.registryLines.joined(separator: "\n") + "\n")
        #expect(text.contains(#""LeftOptionIsAlt"="y""#))
        let everything = FileManager.default.enumerator(atPath: work.path)?.allObjects as? [String] ?? []
        #expect(everything.sorted() == ["setups", "setups/1145360.keyboard"])
    }

    // The run script's own check: the lines it adds to the prefix import
    @Test("settingscheck: the run script imports the game's keyboard options and nothing else from the file")
    func runScript() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [repo.appending(path: "dylib/tests/settingscheck.sh").path, repo.appending(path: "dylib/feats/compat_run.sh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("ok    the game's keyboard options join the import, other lines are dropped"))
    }
}
