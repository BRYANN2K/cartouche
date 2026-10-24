import Foundation
import Testing
@testable import InstallerKit

// Files are text except where a size or a signature matters: those are sparse or start with MZ.
private func folder(_ files: [String: String], sized: [String: Int64] = [:], binary: [String: Data] = [:]) throws -> URL {
    let dir = try tempFolder(files)
    for (path, size) in sized {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("MZ".utf8))
        try FileHandle(forWritingTo: url).truncate(atOffset: UInt64(size))
    }
    for (path, data) in binary {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    return dir
}

private func pe(_ text: String, utf16: Bool = false) -> Data {
    Data("MZ".utf8) + Data(count: 4096) + (utf16 ? text.data(using: .utf16LittleEndian)! : Data(text.utf8)) + Data(count: 64)
}

private func names(_ scan: ExeDetector.Scan) -> [String] {
    scan.candidates.map { ($0.path as NSString).lastPathComponent }
}

@Suite("Dropped folder")
struct DroppedFolderTests {

    @Test("A Unity game: Game.exe next to Game_Data, with Steam's API")
    func unity() throws {
        let dir = try folder(["UnityPlayer.dll": "", "Game_Data/Plugins/x86_64/steam_api64.dll": "", "UnityCrashHandler64.exe": "MZ"],
                             sized: ["Game.exe": 650_000])
        let found = DroppedFolder.classify(dir)
        #expect(found.kind == .installedGame)
        #expect(found.markers == [.unity, .steamAPI])
        #expect(names(ExeDetector.scan(gameFolder: dir)) == ["Game.exe"])
    }

    @Test("An Unreal game: Engine, the shipping build in Binaries/Win64, and .pak files")
    func unreal() throws {
        let dir = try folder(["Engine/Binaries/ThirdParty/Ogg/libogg.dll": "",
                              "Engine/Extras/Redist/en-us/UE4PrereqSetup_x64.exe": "MZ",
                              "MyGame/Content/Paks/MyGame-WindowsNoEditor.pak": ""],
                             sized: ["MyGame.exe": 250_000, "MyGame/Binaries/Win64/MyGame-Win64-Shipping.exe": 60 << 20])
        let found = DroppedFolder.classify(dir)
        #expect(found.kind == .installedGame)
        #expect(found.markers == [.unreal, .packages, .largeProgram])
        #expect(names(ExeDetector.scan(gameFolder: dir)) == ["MyGame-Win64-Shipping.exe", "MyGame.exe"])
    }

    @Test("A game installed by Inno Setup: unins000.exe outweighs a settings tool called Setup.exe")
    func installedInno() throws {
        let dir = try folder(["unins000.dat": "", "Setup.exe": "MZ"], sized: ["Game.exe": 3_000_000],
                             binary: ["unins000.exe": pe("JR.Inno.Setup")])
        let found = DroppedFolder.classify(dir)
        #expect(found.kind == .installedGame)
        #expect(found.markers == [.innoUninstaller])
        #expect(names(ExeDetector.scan(gameFolder: dir)) == ["Game.exe"])
    }

    @Test("A game wrapped in one or two folders is found inside them")
    func wrapped() throws {
        let dir = try folder(["readme.txt": "", "Game v1.0/Game/Game_Data/level0": "", "Game v1.0/Game/Game.exe": "MZ", "__MACOSX/x": ""])
        let found = DroppedFolder.classify(dir)
        #expect(found.kind == .installedGame)
        #expect(found.root.lastPathComponent == "Game")
        #expect(found.markers == [.unity])
    }

    @Test("A real installer next to the game's own program stays an installer and its setup is chosen")
    func installerWithGameExe() throws {
        let dir = try folder([:], sized: ["game.exe": 20 << 20], binary: ["setup_game_1.0.exe": pe("Inno Setup", utf16: true)])
        #expect(DroppedFolder.classify(dir).kind == .installer)
        #expect(try PartScanner.scan(dir).setup?.lastPathComponent == "setup_game_1.0.exe")
    }

    @Test("An installer with any name is found by its signature, not by sorting first")
    func signatureOnly() throws {
        let dir = try folder(["a-tool.exe": "MZ"], binary: ["My Game.exe": pe("Nullsoft.NSIS.exehead")])
        #expect(DroppedFolder.classify(dir).kind == .installer)
        #expect(try PartScanner.scan(dir).setup?.lastPathComponent == "My Game.exe")
    }

    @Test("setup.exe with .bin parts is an installer")
    func parts() throws {
        let dir = try folder(["setup.exe": "MZ", "data-01.bin": "a", "data-02.bin": "b", "MD5/checksums.md5": ""])
        #expect(DroppedFolder.classify(dir).kind == .installer)
    }

    @Test("A folder with no program at all goes the installer way, which reports the missing setup")
    func empty() throws {
        #expect(DroppedFolder.classify(try folder(["readme.txt": ""])).kind == .installer)
    }

    @Test("A program with no installer signature and no setup name is a game, even without markers")
    func unsure() throws {
        #expect(DroppedFolder.classify(try folder(["Game.exe": "MZ"])).kind == .installedGame)
    }

    @Test("The analysis of an installed game never runs innoextract and has no setup")
    func analysis() throws {
        let runner = RecordingRunner(answers: ["--info": "Not a supported Inno Setup installer!"])
        let dir = try folder(["Pack/Game/Game_Data/x": ""], sized: ["Pack/Game/Game.exe": 1_000])
        let analysis = try Analyzer.inspect(dir, tool: "/x/innoextract", runner: runner)
        #expect(analysis.isInstalledGame)
        #expect(analysis.scan.setup == nil)
        #expect(analysis.canInstall)
        #expect(analysis.folder.lastPathComponent == "Game")
        #expect(analysis.name == "Game")
        #expect(runner.calls.isEmpty)
    }

    @Test("The size of a game counts every file")
    func size() throws {
        let dir = try folder(["a/b.txt": "12345"], sized: ["Game.exe": 1_000])
        #expect(DroppedFolder.size(of: dir) == 1_005)
    }
}
