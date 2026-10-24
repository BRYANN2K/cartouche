import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// An installed game record, its launcher, and the game's files either in the drop staging (Caches) or in
// a folder of the user's own.
private struct StagedScene {
    let work: URL
    let installs: URL
    let staging: URL
    let source: URL
    let folder: GameFolder

    init(_ label: String, staged: Bool = true) throws {
        work = try scratchDirectory(label)
        installs = work.appending(path: "installs")
        staging = work.appending(path: "Library/Caches/Cartouche/DropStaging")
        source = staged ? staging.appending(path: "Sample-Game-Archive/Sample Game") : work.appending(path: "Games/Sample Game")
        folder = GameFolder(root: installs.appending(path: "sample-game"))
        let fm = FileManager.default
        try fm.createDirectory(at: source.appending(path: "Data"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.prefix.appending(path: "drive_c"), withIntermediateDirectories: true)
        try Data("MZ sample".utf8).write(to: exe)
        try Data(repeating: 7, count: 64 << 10).write(to: source.appending(path: "Data/level.pak"))
        let bin = work.appending(path: "wine/bin")
        let wine = WineRunner(root: work.appending(path: "wine"), loader: bin.appending(path: "wine"),
                              server: bin.appending(path: "wineserver"), dllPath: "")
        try GameLauncher.write(exe: exe, folder: folder, wine: wine)
        let record = InstalledGame(
            id: "sample-game", name: "Sample Game", appID: nil, gogID: nil,
            runnerID: "r", graphics: GraphicsBackend.wined3d.rawValue, wineVersion: nil, wineRunnerKind: nil,
            prefix: folder.prefix.path(percentEncoded: false), exe: exe.path(percentEncoded: false),
            installedAt: Date(), installerFolder: source.path(percentEncoded: false),
            redistributables: [], gameFolder: source.path(percentEncoded: false))
        try InstalledGames.save(record, in: folder)
    }

    var exe: URL { source.appending(path: "Sample Game.exe") }
    var home: URL { StagedGames.home(for: "Sample Game", prefix: folder.prefix) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func migrate(allowRename: Bool = true, freeSpace: @escaping (URL) -> Int64? = { _ in Int64.max },
                 inUse: @escaping (GameFolder) -> Bool = { _ in false }) -> [String] {
        StagedGames.migrate(installs: installs, staging: staging, allowRename: allowRename,
                            freeSpace: freeSpace, inUse: inUse)
    }
}

@Suite("Games extracted from a drop", .serialized)
struct StagedGamesTests {

    @Test("A record left in the drop staging moves into its prefix; game.json and the launcher follow",
          arguments: [true, false])
    func migrates(sameVolume: Bool) throws {
        let scene = try StagedScene("staged-migrate-\(sameVolume)")
        #expect(scene.migrate(allowRename: sameVolume) == ["sample-game"])

        let record = try #require(InstalledGames.record(in: scene.folder))
        let exe = scene.home.appending(path: "Sample Game.exe")
        #expect(record.exe == exe.path(percentEncoded: false))
        #expect(record.gameFolder == nil)
        #expect(!StagedGames.isStaged(record.exeURL, staging: scene.staging))
        #expect(scene.exists(exe))
        #expect(scene.exists(scene.home.appending(path: "Data/level.pak")))
        #expect(GameMove.tally(scene.home) == GameMove.Tally(files: 2, bytes: Int64("MZ sample".utf8.count) + (64 << 10)))
        #expect(!scene.exists(scene.source))
        #expect(!scene.exists(scene.source.deletingLastPathComponent()), "the emptied archive folder goes too")

        let launcher = try String(contentsOf: scene.folder.launcher, encoding: .utf8)
        #expect(launcher.contains(GameLauncher.quote(exe.path(percentEncoded: false))))
        #expect(launcher.contains("cd '\(scene.home.path(percentEncoded: false))"))
        #expect(!launcher.contains(scene.source.path(percentEncoded: false)))
        #expect(FileManager.default.isExecutableFile(atPath: scene.folder.launcher.path(percentEncoded: false)))
        // Owned by Cartouche now: removal offers Uninstall, not "Remove from Library".
        #expect(!GameUninstall.inPlace(scene.folder))

        #expect(scene.migrate().isEmpty, "a second start finds nothing left to move")
    }

    @Test("A move without the space for it fails cleanly: the record, launcher and files stay where they were")
    func noSpaceKeepsOriginal() throws {
        let scene = try StagedScene("staged-no-space")
        let record = try Data(contentsOf: scene.folder.record)
        let launcher = try Data(contentsOf: scene.folder.launcher)
        #expect(scene.migrate(allowRename: false, freeSpace: { _ in 1024 }).isEmpty)

        #expect(try Data(contentsOf: scene.folder.record) == record)
        #expect(try Data(contentsOf: scene.folder.launcher) == launcher)
        #expect(scene.exists(scene.exe))
        #expect(!scene.exists(scene.home))
        let games = scene.home.deletingLastPathComponent()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: games.path(percentEncoded: false))) ?? []).isEmpty,
                "no partial copy is left behind")
    }

    @Test("A copy stopped halfway leaves the original whole and no partial folder")
    func interruptedCopyKeepsOriginal() throws {
        let scene = try StagedScene("staged-stopped")
        let before = GameMove.tally(scene.source)
        let stop = StopFlag()
        stop.set()
        #expect(throws: CancellationError.self) {
            try GameMove.place(scene.source, at: scene.home, allowRename: false, freeSpace: { _ in Int64.max }, stop: stop)
        }
        #expect(GameMove.tally(scene.source) == before)
        #expect(!scene.exists(scene.home))
        #expect(!scene.exists(scene.home.deletingLastPathComponent().appending(path: ".\(scene.home.lastPathComponent).moving")))
        #expect(InstalledGames.record(in: scene.folder)?.exe == scene.exe.path(percentEncoded: false))
    }

    @Test("Files moved by a run that stopped before the record are adopted at the next start")
    func resumesAfterRename() throws {
        let scene = try StagedScene("staged-resume")
        try FileManager.default.createDirectory(at: scene.home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: scene.source, to: scene.home)
        #expect(scene.migrate() == ["sample-game"])
        let record = try #require(InstalledGames.record(in: scene.folder))
        #expect(record.exe == scene.home.appending(path: "Sample Game.exe").path(percentEncoded: false))
        #expect(scene.exists(record.exeURL))
    }

    @Test("A game that is running waits for the next start")
    func busyGameWaits() throws {
        let scene = try StagedScene("staged-busy")
        #expect(scene.migrate(inUse: { _ in true }).isEmpty)
        #expect(scene.exists(scene.exe))
        #expect(InstalledGames.record(in: scene.folder)?.gameFolder == scene.source.path(percentEncoded: false))
    }

    @Test("A folder of the user's own, used in place, is never moved or rewritten")
    func userFolderUntouched() throws {
        let scene = try StagedScene("staged-user-folder", staged: false)
        let record = try Data(contentsOf: scene.folder.record)
        let launcher = try Data(contentsOf: scene.folder.launcher)
        #expect(scene.migrate().isEmpty)
        #expect(try Data(contentsOf: scene.folder.record) == record)
        #expect(try Data(contentsOf: scene.folder.launcher) == launcher)
        #expect(scene.exists(scene.exe))
        #expect(!scene.exists(scene.home))
        #expect(GameUninstall.inPlace(scene.folder))
        #expect(!StagedGames.isStaged(scene.source, staging: scene.staging))
    }

    @Test("Staging is matched by path, also through /private and a trailing slash")
    func stagedPaths() {
        let staging = URL(filePath: "/var/folders/x/Library/Caches/Cartouche/DropStaging", directoryHint: .isDirectory)
        #expect(StagedGames.isStaged(URL(filePath: "/private/var/folders/x/Library/Caches/Cartouche/DropStaging/Game/a.exe"), staging: staging))
        #expect(StagedGames.isStaged(staging.appending(path: "Game"), staging: staging))
        #expect(!StagedGames.isStaged(staging, staging: staging))
        #expect(!StagedGames.isStaged(URL(filePath: "/var/folders/x/Library/Caches/Cartouche/DropStagingOther/a.exe"), staging: staging))
        #expect(!StagedGames.isStaged(URL(filePath: "/Volumes/Games/Witcher 3/witcher3.exe"), staging: staging))
    }
}
