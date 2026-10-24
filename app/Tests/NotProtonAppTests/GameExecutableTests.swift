import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Starts With on scratch installs: fixture runners, no real Wine or winetricks runs.
@MainActor
@Suite("Game executable")
struct GameExecutableTests {

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x4D, count: bytes).write(to: url)
    }

    private func center(_ work: URL, installs: URL) -> InstallCenter {
        InstallCenter(engine: InstallEngine(installs: installs, runners: work.appending(path: "runners"),
                                            registry: { RunnerRegistry() }),
                      notifier: RecordingNotifier())
    }

    @Test("The choices follow the install sheet: game first, launcher marked, redistributables, anti-cheat setup and uninstaller left out")
    func importedChoices() throws {
        let work = try scratchDirectory("exe-choices")
        defer { try? FileManager.default.removeItem(at: work) }
        let game = work.appending(path: "CarX Street")
        try write(3000, to: game.appending(path: "CarX Street.exe"))
        try write(2000, to: game.appending(path: "CarX Street Launcher.exe"))
        try write(500, to: game.appending(path: "unins000.exe"))
        try write(800, to: game.appending(path: "_Redist/vcredist_x64.exe"))
        try write(900, to: game.appending(path: "EasyAntiCheat/EasyAntiCheat_Setup.exe"))
        let record = InstalledGame(
            id: "carx-street", name: "CarX Street", appID: nil, gogID: nil, runnerID: "r", graphics: nil,
            wineVersion: nil, wineRunnerKind: nil, prefix: work.appending(path: "installs/carx-street/pfx").path,
            exe: game.appending(path: "CarX Street.exe").path, installedAt: Date(),
            installerFolder: game.path, redistributables: [], gameFolder: game.path)

        let options = GameExecutable.options(for: record)
        #expect(options.choices.map(\.name) == ["CarX Street.exe", "CarX Street Launcher.exe"])
        #expect(options.choices.map(\.isLauncher) == [false, true])
        #expect(GameExecutable.isCurrent(options.choices[0], record.exeURL))

        // A current program the scan leaves out is still listed, first
        let odd = game.appending(path: "bin/odd.exe")
        let listed = GameExecutable.listed(options, current: odd)
        #expect(listed.map(\.name) == ["bin/odd.exe", "CarX Street.exe", "CarX Street Launcher.exe"])
        #expect(GameExecutable.listed(options, current: record.exeURL) == options.choices)
    }

    @Test("A program inside a prefix install is found in the folder the install made")
    func installedChoices() throws {
        let work = try scratchDirectory("exe-prefix")
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = try InstallerSetupTests.installed(in: work.appending(path: "installs"))
        let dir = folder.prefix.appending(path: "drive_c/Games/Sample")
        try write(4000, to: dir.appending(path: "Sample Launcher.exe"))
        let record = try #require(InstalledGames.record(in: folder))
        let options = GameExecutable.options(for: record)
        #expect(options.folder.standardizedFileURL.pathComponents == dir.standardizedFileURL.pathComponents)
        #expect(Set(options.choices.map(\.name)) == ["game.exe", "Sample Launcher.exe"])
        #expect(options.choices.first { $0.name == "Sample Launcher.exe" }?.isLauncher == true)
    }

    @Test("Changing the program rewrites the record and the launcher, keeps the setup and leaves the prefix alone")
    func changeRewrites() async throws {
        let work = try scratchDirectory("exe-change")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let free = try InstallerSetupTests.freeWine("wine-11.0", version: "11.0", in: runners)
        let folder = try InstallerSetupTests.installed(in: installs)
        let launcherExe = folder.prefix.appending(path: "drive_c/Games/Sample/Sample Launcher.exe")
        try write(100, to: launcherExe)
        let before = try InstallerSetupTests.snapshot(folder.prefix)
        let model = InstallerSetupTests.model(in: work, installs: installs, runners: [free],
                                              runnersFolder: runners, backends: work.appending(path: "backends"))
        let verbs = VerbLog()
        model.exeWinetricks = { list, _, _, _ in
            verbs.add(list)
            return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:]))
        }
        let game = try #require(model.game("installer:sample"))

        await model.changeExe(of: game, to: launcherExe, installs: center(work, installs: installs))
        #expect(model.problem == nil)
        #expect(model.changingExe.isEmpty)
        let record = try #require(InstallerSetupTests.record(in: folder))
        #expect(record.exe == launcherExe.standardizedFileURL.path(percentEncoded: false))
        #expect(record.runnerID == "wine-11.0")
        #expect(record.graphics == GraphicsBackend.wined3d.rawValue)
        let script = try String(contentsOf: folder.launcher, encoding: .utf8)
        #expect(script.contains(GameLauncher.quote(launcherExe.standardizedFileURL.path(percentEncoded: false))))
        #expect(script.contains("wine-11.0/bin/wine"))
        #expect(!script.contains("Games/Sample/game.exe"))
        #expect(model.game("installer:sample")?.executable?.lastPathComponent == "Sample Launcher.exe")
        // A program that links nothing Wine lacks installs no runtime
        #expect(verbs.calls.isEmpty)
        #expect(try InstallerSetupTests.snapshot(folder.prefix) == before)
    }

    @Test("A file outside the game's folder is refused and nothing changes")
    func outsideRefused() async throws {
        let work = try scratchDirectory("exe-outside")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let free = try InstallerSetupTests.freeWine("wine-11.0", in: runners)
        let folder = try InstallerSetupTests.installed(in: installs)
        let stray = work.appending(path: "Downloads/other.exe")
        try write(100, to: stray)
        let model = InstallerSetupTests.model(in: work, installs: installs, runners: [free],
                                              runnersFolder: runners, backends: work.appending(path: "backends"))
        let game = try #require(model.game("installer:sample"))
        let old = try #require(InstallerSetupTests.record(in: folder)).exe

        await model.changeExe(of: game, to: stray, installs: center(work, installs: installs))
        #expect(model.problem != nil)
        #expect(InstallerSetupTests.record(in: folder)?.exe == old)
        #expect(!FileManager.default.fileExists(atPath: folder.launcher.path))
    }

    @Test("Starts With lists the folder's programs and is disabled while the game runs")
    func disabledWhileRunning() async throws {
        let work = try scratchDirectory("exe-busy")
        defer { try? FileManager.default.removeItem(at: work) }
        let installs = work.appending(path: "installs")
        let runners = work.appending(path: "runners")
        let free = try InstallerSetupTests.freeWine("wine-11.0", in: runners)
        let folder = try InstallerSetupTests.installed(in: installs)
        let launcherExe = folder.prefix.appending(path: "drive_c/Games/Sample/Sample Launcher.exe")
        try write(100, to: launcherExe)
        let model = InstallerSetupTests.model(in: work, installs: installs, runners: [free],
                                              runnersFolder: runners, backends: work.appending(path: "backends"))
        let game = try #require(model.game("installer:sample"))
        let c = center(work, installs: installs)
        func item() -> GameMenuItem? {
            GameMenu.items(for: game, in: model, installs: c).first { $0.title == "Starts With" }
        }
        #expect(await waitFor { model.exeOptions[game.id] != nil })
        let menu = try #require(item())
        #expect(menu.disabled == false)
        #expect(menu.children.first { $0.checked }?.action == .startsWith(game.executable!.standardizedFileURL.path(percentEncoded: false)))
        #expect(menu.children.contains { $0.title == "Sample Launcher.exe (Launcher)" })
        #expect(menu.children.last?.action == .chooseExe)

        c.prefixUse = { _ in .running(.game) }
        c.refreshBusy(for: [game], in: installs)
        #expect(await waitFor { c.busyGames.contains(game.id) })
        #expect(item()?.disabled == true)
        #expect(!model.canChangeExe(game, installs: c))
        let old = try #require(InstallerSetupTests.record(in: folder)).exe
        await model.changeExe(of: game, to: launcherExe, installs: c)
        #expect(InstallerSetupTests.record(in: folder)?.exe == old)

        // A change already under way holds the menu too
        c.prefixUse = { _ in .free }
        c.refreshBusy(for: [game], in: installs)
        #expect(await waitFor { !c.busyGames.contains(game.id) })
        model.changingExe.insert(game.id)
        #expect(item()?.disabled == true)
    }

    @Test("Only the runtimes the prefix lacks are installed; a failed or stuck verb is left out of the record")
    func runtimes() async throws {
        let work = try scratchDirectory("exe-runtimes")
        defer { try? FileManager.default.removeItem(at: work) }
        let steps = [RuntimeStep(verb: "vcrun2022", label: "Visual C++ 2015–2022"),
                     RuntimeStep(verb: "d3dx9", label: "DirectX 9"),
                     RuntimeStep(verb: "openal", label: "OpenAL"),
                     RuntimeStep(verb: "physx", label: "PhysX")]
        let missing = GameExecutable.missing(steps, installed: ["d3dx9"])
        #expect(missing.map(\.verb) == ["vcrun2022", "openal", "physx"])

        let wine = WineRunner(root: work, loader: work.appending(path: "bin/wine"),
                              server: work.appending(path: "bin/wineserver"), dllPath: "")
        let installed = await GameExecutable.install(
            missing, prefix: work.appending(path: "pfx"), wine: wine, log: work.appending(path: "winetricks.log"),
            timeout: 1
        ) { verbs, _, _, _ in
            let body = verbs == ["openal"] ? "exit 1" : verbs == ["physx"] ? "sleep 30" : "exit 0"
            return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", body], environment: [:]))
        }
        #expect(installed == ["vcrun2022"])
    }
}
