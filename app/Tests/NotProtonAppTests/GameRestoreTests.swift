import Foundation
import Testing
@testable import NotProtonApp

@Suite("Fullscreen game restore after the menu")
struct GameRestoreTests {
    let helper = URL(filePath: "/Applications/Cartouche.app/Contents/Resources/payload/game-restore.exe")
    let wine: [String: String] = [
        "WINELOADER": "/runners/d3dmetal/bin/wine", "WINEPREFIX": "/installs/cobalt-street/pfx",
        "WINESERVER": "/runners/d3dmetal/bin/wineserver", "WINEDEBUG": "+relay", "HOME": "/Users/me", "PATH": "/usr/bin",
    ]

    @Test("Runs the helper in the game's own Wine with the game's exe name")
    func command() throws {
        let info = GameProcesses.Info(path: "/runners/d3dmetal/bin/wine", arguments: ["/Users/me/Downloads/Cobalt Street/Cobalt Street.exe"], environment: wine)
        let command = try #require(GameRestore.command(for: info, helper: helper))
        #expect(command.executable == "/usr/bin/arch")
        #expect(command.arguments == ["-x86_64", "/runners/d3dmetal/bin/wine", helper.path(percentEncoded: false), "Cobalt Street.exe"])
        #expect(command.environment["WINEPREFIX"] == "/installs/cobalt-street/pfx")
        #expect(command.environment["WINESERVER"] == "/runners/d3dmetal/bin/wineserver")
        #expect(command.environment["WINEDEBUG"] == "-all")
        #expect(command.environment["HOME"] == nil)
    }

    @Test("A Windows path names the exe too")
    func windowsPath() throws {
        let info = GameProcesses.Info(path: "/runners/wine", arguments: ["C:\\Program Files\\Game\\Game.EXE", "-fullscreen"], environment: wine)
        #expect(try #require(GameRestore.command(for: info, helper: helper)).arguments.last == "Game.EXE")
    }

    @Test("No Wine environment or no exe: nothing runs")
    func notWine() {
        let native = GameProcesses.Info(path: "/Applications/Game.app/Contents/MacOS/Game", arguments: ["Game.exe"], environment: ["HOME": "/Users/me"])
        #expect(GameRestore.command(for: native, helper: helper) == nil)
        let noExe = GameProcesses.Info(path: "/runners/wine", arguments: ["explorer"], environment: wine)
        #expect(GameRestore.command(for: noExe, helper: helper) == nil)
    }
}
