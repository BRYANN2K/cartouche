import AppKit
import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// A finished install under a scratch installs/: prefix with a game, a launcher and a record.
// The injected trash moves paths into bin/, so the test sees exactly what the Trash would get.
@MainActor
@Suite("Installer game removal")
struct InstallUninstallTests {

    private struct Scene {
        let work: URL
        let installs: URL
        let folder: GameFolder
        let external: URL
        let game: Game
        let model: LibraryModel
        let fixture: SteamFixture
        let bin: URL
        let saves: URL
    }

    private func scene(_ label: String, name: String = "Sample Game",
                       inPlace: Bool = false, legacy: Bool = false, saves: Bool = false) throws -> Scene {
        let work = try scratchDirectory(label)
        let installs = work.appending(path: "installs")
        let external = work.appending(path: "External/\(name)")
        let folder = GameFolder(root: installs.appending(path: GameFolder.slug(name)))
        let fm = FileManager.default
        let gameDir = inPlace ? external : folder.prefix.appending(path: "drive_c/Games/Sample Game")
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: gameDir.appending(path: "game.exe"))
        try fm.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        try Data("launch".utf8).write(to: folder.launcher)
        // A legacy record predates gameFolder: the folder it was imported from is the hint.
        let record = InstalledGame(
            id: folder.root.lastPathComponent, name: name, appID: nil, gogID: nil,
            runnerID: "r", graphics: GraphicsBackend.wined3d.rawValue, wineVersion: nil, wineRunnerKind: nil,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: gameDir.appending(path: "game.exe").path(percentEncoded: false),
            installedAt: Date(),
            installerFolder: legacy ? external.path(percentEncoded: false) : work.path(percentEncoded: false),
            redistributables: [], gameFolder: inPlace && !legacy ? external.path(percentEncoded: false) : nil)
        try InstalledGames.save(record, in: folder)
        if saves {
            for rel in ["AppData/Game", "Saved Games/Game", "Documents/My Games/Game"] {
                let dir = folder.prefix.appending(path: "drive_c/users/crossover/\(rel)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("save".utf8).write(to: dir.appending(path: "save.dat"))
            }
            let other = folder.prefix.appending(path: "drive_c/users/crossover/Desktop")
            try fm.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("not a save".utf8).write(to: other.appending(path: "notes.txt"))
        }
        let fixture = try SteamFixture("\(label)-steam")
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        model.installsFolder = installs
        model.showInstalledGames(InstalledGames.all(in: installs))
        return Scene(work: work, installs: installs, folder: folder, external: external,
                     game: try #require(model.game("installer:\(folder.root.lastPathComponent)")),
                     model: model, fixture: fixture,
                     bin: work.appending(path: "bin"), saves: work.appending(path: "saves"))
    }

    private func center(_ s: Scene) -> InstallCenter {
        InstallCenter(engine: InstallEngine(installs: s.installs, runners: s.work.appending(path: "runners"),
                                            registry: { RunnerRegistry() }),
                      notifier: RecordingNotifier())
    }

    private func runner(_ s: Scene, answer: RemovalAnswer = .moveToTrash(keepSaves: true)) throws -> (GameActionRunner, Box<[RemovalPlan]>) {
        try FileManager.default.createDirectory(at: s.bin, withIntermediateDirectories: true)
        let bin = s.bin
        var runner = GameActionRunner(model: s.model, open: { _ in })
        runner.uninstall.trash = { try FileManager.default.moveItem(at: $0, to: bin.appending(path: $0.lastPathComponent)) }
        runner.uninstall.saves = s.saves
        let plans = Box<[RemovalPlan]>([])
        runner.confirmRemoval = { plans.value.append($0); return answer }
        return (runner, plans)
    }

    private func item(_ s: Scene, installs: InstallCenter? = nil) -> GameMenuItem? {
        GameMenu.items(for: s.game, in: s.model, installs: installs).first { $0.action == .uninstall }
    }

    @Test("Installed or copied: the menu shows Uninstall…, in place it shows Remove from Library…")
    func itemTitle() throws {
        let installed = try scene("remove-kind-installed")
        #expect(item(installed)?.title == "Uninstall…")
        #expect(item(installed)?.destructive == true)
        #expect(item(installed)?.disabled == false)
        let imported = try scene("remove-kind-imported", inPlace: true)
        #expect(item(imported)?.title == "Remove from Library…")
        #expect(item(imported)?.destructive == true)
    }

    @Test("The item sits in its own section above Hide Game")
    func itemPlacement() throws {
        let s = try scene("remove-placement")
        let items = GameMenu.items(for: s.game, in: s.model, installs: center(s))
        let uninstall = try #require(items.firstIndex { $0.action == .uninstall })
        let hide = try #require(items.firstIndex { $0.action == .hide })
        #expect(uninstall < hide)
        #expect(items[uninstall - 1].isDivider)
        #expect(items[uninstall + 1].isDivider)
    }

    @Test("Building the menu never runs the prefix probe; it reads the last off-thread answer")
    func menuNeverProbes() async throws {
        let s = try scene("remove-noprobe")
        let c = center(s)
        let calls = Box(0)
        let onMain = Box(false)
        c.prefixUse = { _ in
            calls.value += 1
            onMain.value = onMain.value || Thread.isMainThread
            return .running(.game)
        }
        #expect(item(s, installs: c)?.disabled == false)
        #expect(calls.value == 0)

        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyGames.contains(s.game.id) })
        let probed = calls.value
        #expect(probed > 0)
        #expect(item(s, installs: c)?.disabled == true)
        #expect(calls.value == probed)
        #expect(!onMain.value)
    }

    @Test("Disabled while the cached flag or an install job is on the game")
    func disabledWhileBusy() async throws {
        let s = try scene("remove-busy")
        let c = center(s)
        #expect(item(s, installs: c)?.disabled == false)
        c.prefixUse = { _ in .running(.game) }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { c.busyGames.contains(s.game.id) })
        #expect(item(s, installs: c)?.disabled == true)
        c.prefixUse = { _ in .free }
        c.refreshBusy(for: [s.game], in: s.installs)
        #expect(await waitFor { !c.busyGames.contains(s.game.id) })
        #expect(item(s, installs: c)?.disabled == false)

        let job = InstallJob(request: InstallRequest(setup: s.work, source: s.work, name: "Sample Game",
                                                   appID: nil, gogID: nil, expectedBytes: 0, installerBytes: 0,
                                                   installerFiles: [], manifest: nil),
                             inputs: InstallInputs(runnerID: "r", gameName: "Sample Game"))
        job.folder = s.folder
        job.phase = .choosing
        c.enqueue(job)
        #expect(item(s, installs: c)?.disabled == true)
        job.phase = .ready
        #expect(item(s, installs: c)?.disabled == false)
    }

    @Test("Uninstall moves only the game's folder to the Trash and drops the record and cover")
    func uninstallMovesFolder() async throws {
        let s = try scene("remove-uninstall")
        let (actions, _) = try runner(s)
        let fm = FileManager.default

        let png = s.work.appending(path: "cover.png")
        try SteamFixture.png("cover", size: CGSize(width: 30, height: 45), hue: 0.5).write(to: png)
        s.model.setCover(png, for: s.game.id)
        let cover = try #require(s.model.coverOverride(for: s.game.id))

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        let trashed = s.bin.appending(path: s.folder.root.lastPathComponent)
        #expect(fm.fileExists(atPath: trashed.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: trashed.appending(path: "game.json").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: s.folder.root.path(percentEncoded: false)))
        #expect(s.model.game(s.game.id) == nil)
        #expect(s.model.coverOverride(for: s.game.id) == nil)
        #expect(!fm.fileExists(atPath: cover.path(percentEncoded: false)))
    }

    @Test("An in-place import keeps its files; only the prefix and record go")
    func inPlaceKeepsGame() async throws {
        let s = try scene("remove-in-place", inPlace: true)
        let (actions, _) = try runner(s)
        let fm = FileManager.default

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        #expect(fm.fileExists(atPath: s.bin.appending(path: s.folder.root.lastPathComponent).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: s.external.appending(path: "game.exe").path(percentEncoded: false)))
    }

    @Test("A record written before gameFolder is still an in-place import: it removes, never deletes")
    func legacyInPlace() async throws {
        let s = try scene("remove-legacy", inPlace: true, legacy: true)
        let (actions, plans) = try runner(s)
        let fm = FileManager.default
        #expect(try #require(InstalledGames.record(in: s.folder)).gameFolder == nil)
        #expect(item(s)?.title == "Remove from Library…")

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        #expect(plans.value.first?.inPlace == true)
        // Only Cartouche's folder goes: the game's own files were never Cartouche's.
        #expect(fm.fileExists(atPath: s.external.appending(path: "game.exe").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: s.bin.appending(path: s.folder.root.lastPathComponent).path(percentEncoded: false)))
    }

    @Test("An exe inside the prefix is never called in-place, gameFolder or not")
    func legacyInstalledStaysUninstall() throws {
        let s = try scene("remove-legacy-installed", legacy: true)
        #expect(item(s)?.title == "Uninstall…")
    }

    @Test("Keep save files copies them to saves/<game id>/ before the prefix goes")
    func keepsSaves() async throws {
        let s = try scene("remove-saves", saves: true)
        let (actions, plans) = try runner(s)
        let fm = FileManager.default

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        #expect(plans.value.first?.hasSaves == true)
        #expect(plans.value.first?.inPlace == false)
        let root = s.saves.appending(path: "\(s.folder.root.lastPathComponent)/crossover")
        for rel in ["AppData/Game/save.dat", "Saved Games/Game/save.dat", "Documents/My Games/Game/save.dat"] {
            #expect(fm.fileExists(atPath: root.appending(path: rel).path(percentEncoded: false)), "\(rel)")
        }
        #expect(!fm.fileExists(atPath: root.appending(path: "Desktop/notes.txt").path(percentEncoded: false)))
    }

    @Test("Saves kept by an earlier removal of the same game stay, and the new ones go next to them")
    func keepsSavesTwice() async throws {
        let s = try scene("remove-saves-twice", saves: true)
        let fm = FileManager.default
        let earlier = s.saves.appending(path: "\(s.folder.root.lastPathComponent)/crossover/AppData/Game")
        try fm.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: earlier.appending(path: "save.dat"))
        let (actions, _) = try runner(s)

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        #expect(try Data(contentsOf: earlier.appending(path: "save.dat")) == Data("older".utf8))
        let root = s.saves.appending(path: "\(s.folder.root.lastPathComponent)-2/crossover")
        #expect(fm.fileExists(atPath: root.appending(path: "AppData/Game/save.dat").path(percentEncoded: false)))
    }

    @Test("Without the checkbox nothing is copied; cancel moves nothing")
    func noSavesAndCancel() async throws {
        let s = try scene("remove-nosave", saves: true)
        let (actions, _) = try runner(s, answer: .moveToTrash(keepSaves: false))
        let fm = FileManager.default

        actions.perform(.uninstall, on: s.game)
        #expect(await waitFor { s.model.game(s.game.id) == nil })
        #expect(fm.fileExists(atPath: s.bin.appending(path: s.folder.root.lastPathComponent).path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: s.saves.appending(path: s.folder.root.lastPathComponent).path(percentEncoded: false)))

        let kept = try scene("remove-cancel")
        let (cancel, cancelPlans) = try runner(kept, answer: .cancel)
        cancel.perform(.uninstall, on: kept.game)
        #expect(await waitFor { !cancelPlans.value.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fm.fileExists(atPath: kept.folder.root.path(percentEncoded: false)))
        #expect(kept.model.game(kept.game.id) != nil)
    }

    @Test("A busy prefix refuses: nothing moves, the record stays")
    func busyRefuses() async throws {
        let s = try scene("remove-refuse")
        var (actions, _) = try runner(s)
        let probed = Box(0)
        actions.uninstall.inUse = { _ in probed.value += 1; return true }
        let fm = FileManager.default

        actions.perform(.uninstall, on: s.game)
        // The plan ran off the main actor, saw the busy prefix and never asked.
        #expect(await waitFor { probed.value > 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fm.fileExists(atPath: s.bin.appending(path: s.folder.root.lastPathComponent).path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: s.folder.root.path(percentEncoded: false)))
        #expect(s.model.game(s.game.id) != nil)
    }

    @Test("The finished record's graphics is the resolved default, not hard-coded wined3d")
    func finishGraphics() async throws {
        let work = try scratchDirectory("finish-graphics")
        let runners = work.appending(path: "runners")
        let installs = work.appending(path: "installs")
        let runner = try fakeRunner(in: runners)
        let folder = GameFolder(root: installs.appending(path: "sample-game"))
        try FileManager.default.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        var engine = InstallEngine(installs: installs, runners: runners,
                                 registry: { RunnerRegistry(runners: [runner]) })
        engine.setupDefaults = { SetupDefaults() }
        engine.backendAvailability = { _, _ in BackendAvailability() }
        let job = InstallJob(request: InstallRequest(setup: work, source: work, name: "Sample Game",
                                                   appID: nil, gogID: nil, expectedBytes: 0, installerBytes: 0,
                                                   installerFiles: [], manifest: nil),
                             inputs: InstallInputs(runnerID: runner.id, gameName: "Sample Game"))
        job.folder = folder
        _ = try await engine.finish(job, exe: folder.prefix.appending(path: "drive_c/Games/game.exe"), showInSteam: false)
        let record = try #require(InstalledGames.record(in: folder))
        // A CrossOver runner without D3DMetal offers DXMT first, like any other Windows game.
        #expect(record.backend == .dxmt)
        #expect(record.graphics == "dxmt")
        #expect(try String(contentsOf: record.launcher, encoding: .utf8).contains("CX_GRAPHICS_BACKEND"))
    }
}
