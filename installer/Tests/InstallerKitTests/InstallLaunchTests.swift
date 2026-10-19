import Foundation
import Testing
@testable import InstallerKit

let sampleRunner = WineRunner(
    root: URL(filePath: "/R/CrossOver"),
    loader: URL(filePath: "/R/CrossOver/lib/wine/x86_64-unix/wine"),
    server: URL(filePath: "/R/CrossOver/bin/wineserver"),
    dllPath: "/R/CrossOver/lib/wine/x86_64-windows:/R/CrossOver/lib/wine/x86_64-unix"
)

@Suite("Install command")
struct InstallLaunchTests {

    let prefix = URL(filePath: "/S/installs/sample-game/pfx")
    let setup = URL(filePath: "/Volumes/Data/Sample Game Installer/setup.exe")

    @Test("Guided: Rosetta, the runner's loader, the setup path and the Inno options")
    func guided() {
        var inputs = InstallInputs(runnerID: "27.0.0.40921", gameName: "Sample Game: Ünïcode™ Edition", language: "en")
        #expect(inputs.installDir == #"C:\Games\Sample Game Unicode Edition"#)
        inputs.log = #"C:\installer.log"#
        let launch = WineInstall.runSetup(setup, runner: sampleRunner, prefix: prefix, inputs: inputs, base: ["PATH": "/usr/bin"])
        #expect(launch.executable == "/usr/bin/arch")
        #expect(launch.arguments == [
            "-x86_64", "/R/CrossOver/lib/wine/x86_64-unix/wine", "/Volumes/Data/Sample Game Installer/setup.exe",
            #"/DIR=C:\Games\Sample Game Unicode Edition"#, "/NORESTART", #"/LOG=C:\installer.log"#, "/LANG=en",
        ])
        #expect(launch.environment["WINEPREFIX"] == "/S/installs/sample-game/pfx")
        #expect(launch.environment["WINELOADER"] == "/R/CrossOver/lib/wine/x86_64-unix/wine")
        #expect(launch.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
        #expect(launch.environment["PATH"] == "/R/CrossOver/bin:/usr/bin")
        #expect(launch.environment["WINE_CPU_TOPOLOGY"] == nil)
        #expect(launch.currentDirectory?.lastPathComponent == "Sample Game Installer")
    }

    @Test("Automatic adds the silent options")
    func automatic() {
        let inputs = InstallInputs(runnerID: "r", gameName: "X", mode: .automatic)
        let args = WineInstall.runSetup(setup, runner: sampleRunner, prefix: prefix, inputs: inputs, base: [:]).arguments
        #expect(args.suffix(3) == ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NOCANCEL"])
        #expect(!args.contains { $0.hasPrefix("/LANG") })
    }

    @Test("A new prefix is made with wineboot, without the Mono and Gecko prompts")
    func newPrefix() {
        let launch = WineInstall.createPrefix(runner: sampleRunner, prefix: prefix, base: [:])
        #expect(launch.arguments == ["-x86_64", "/R/CrossOver/lib/wine/x86_64-unix/wine", "wineboot", "--init"])
        #expect(launch.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;mscoree,mshtml=")
        #expect(launch.environment["WINEPREFIX"] == prefix.path)
    }

    @Test("Windows paths on drive C map into the prefix and back")
    func paths() {
        let unix = WinePath.unix(#"C:\Games\Sample Game\game.exe"#, prefix: prefix)
        #expect(unix?.path == "/S/installs/sample-game/pfx/drive_c/Games/Sample Game/game.exe")
        #expect(WinePath.windows(unix!, prefix: prefix) == #"C:\Games\Sample Game\game.exe"#)
        #expect(WinePath.unix(#"D:\elsewhere"#, prefix: prefix) == nil)
        #expect(WinePath.folderName("日本語") == "Game")
        #expect(WinePath.folderName(String(repeating: "Long ", count: 20)).count <= 40)
    }

    @Test("The short source path runs setup from drive S")
    func shortSource() throws {
        var inputs = InstallInputs(runnerID: "r", gameName: "X")
        inputs.shortSource = true
        #expect(WineInstall.runSetup(setup, runner: sampleRunner, prefix: prefix, inputs: inputs, base: [:]).arguments[2] == #"S:\setup.exe"#)
        let pfx = try tempFolder([:]).appending(path: "pfx")
        try WineInstall.mapSource(setup.deletingLastPathComponent(), prefix: pfx)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: pfx.appending(path: "dosdevices/s:").path)
        #expect(target == "/Volumes/Data/Sample Game Installer")
    }
}
