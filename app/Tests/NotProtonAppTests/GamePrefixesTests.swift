import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// Settings > Wine Prefixes lists every prefix Cartouche manages, not only Steam's: the
// installer and imported games under installs/, and the store games' folders. Each source
// offers only the actions its prefix can take; a crash never leaves Wine's debugger up.
@MainActor
@Suite("Game prefixes")
struct GamePrefixesTests {

    private struct Scene {
        let work: URL
        let installs: URL
        let stores: StoreFolders
        let installer: URL
        let store: URL
    }

    private func scene(_ label: String) throws -> Scene {
        let work = try scratchDirectory(label)
        let installs = work.appending(path: "installs")
        let stores = StoreFolders(root: work.appending(path: "stores", directoryHint: .isDirectory))
        let fm = FileManager.default

        let folder = GameFolder(root: installs.appending(path: "sample-quest"))
        try fm.createDirectory(at: folder.prefix.appending(path: "drive_c/Games/Sample Quest"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: folder.prefix.appending(path: "drive_c/Games/Sample Quest/quest.exe"))
        let record = InstalledGame(
            id: "sample-quest", name: "Sample Quest", appID: nil, gogID: nil,
            runnerID: "wine-crossover-26.3.0-1", graphics: nil, wineVersion: "26.3", wineRunnerKind: "wineBuild",
            prefix: folder.prefix.path(percentEncoded: false),
            exe: folder.prefix.appending(path: "drive_c/Games/Sample Quest/quest.exe").path(percentEncoded: false),
            installedAt: Date(), installerFolder: work.path(percentEncoded: false), redistributables: [])
        try InstalledGames.save(record, in: folder)

        // An unfinished attempt and a folder with no record are not games.
        try fm.createDirectory(at: installs.appending(path: "half-done/pfx"), withIntermediateDirectories: true)

        let storeFolder = stores.gameFolder(.epic, title: "Fennec", id: "Fennec")
        try fm.createDirectory(at: storeFolder.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
        try stores.save(StoreInstalledGame(
            store: "epic", id: "Fennec", title: "Sample Free Game",
            install: StoreInstall(path: work.appending(path: "Games/Fennec"), version: "1"),
            folder: storeFolder, installedAt: Date()))
        // A store game never played has no prefix yet: nothing to list.
        try stores.save(StoreInstalledGame(
            store: "gog", id: "1207658924", title: "Unplayed",
            install: StoreInstall(path: work.appending(path: "Games/Unplayed"), version: nil),
            folder: stores.gameFolder(.gog, title: "Unplayed", id: "1207658924"), installedAt: Date()))
        return Scene(work: work, installs: installs, stores: stores, installer: folder.root, store: storeFolder)
    }

    private func games(_ s: Scene) -> @Sendable (Bool) -> [WinePrefix] {
        let installs = s.installs, stores = s.stores
        return { PrefixStore.games(installs: installs, stores: stores, live: $0) }
    }

    @Test("Installer and store games are listed with their names, source and runner")
    func listsEverySource() throws {
        let s = try scene("game-prefixes-list")
        defer { try? FileManager.default.removeItem(at: s.work) }

        let found = PrefixStore.games(installs: s.installs, stores: s.stores)
        #expect(found.count == 2)
        let installer = try #require(found.first { $0.source == .installer })
        #expect(installer.title == "Sample Quest")
        #expect(installer.root.standardizedFileURL.path == s.installer.standardizedFileURL.path)
        #expect(installer.pfx.standardizedFileURL.path == s.installer.appending(path: "pfx").standardizedFileURL.path)
        #expect(installer.runner == "Cartouche Wine 26.3")
        #expect(installer.source.label == GameSource.installer.name)
        let store = try #require(found.first { $0.source == .store(.epic) })
        #expect(store.title == "Sample Free Game")
        #expect(store.root.standardizedFileURL.path == s.store.standardizedFileURL.path)
        #expect(store.source.label == "Epic Games")
        #expect(store.runner == nil)
        #expect(installer.id != store.id)
        #expect(PrefixStore.games(installs: s.installs, stores: s.stores, live: false).isEmpty)
    }

    @Test("The runner reads as the runner list names it, from what the record kept")
    func runnerLabels() {
        func record(_ id: String, kind: String?, version: String?) -> InstalledGame {
            InstalledGame(id: "g", name: "G", appID: nil, gogID: nil, runnerID: id, graphics: nil,
                          wineVersion: version, wineRunnerKind: kind, prefix: "/p", exe: "/p/g.exe",
                          installedAt: Date(), installerFolder: "/i", redistributables: [])
        }
        #expect(PrefixStore.runnerLabel(record("wine-crossover-26.3.0-1", kind: "wineBuild", version: "26.3")) == "Cartouche Wine 26.3")
        #expect(PrefixStore.runnerLabel(record("wine-11.0", kind: "wineBuild", version: "11.0")) == "Wine 11.0")
        #expect(PrefixStore.runnerLabel(record("crossover-26", kind: "crossOver", version: nil)) == "CrossOver")
        #expect(PrefixStore.runnerLabel(record("old-runner", kind: nil, version: "9.0")) == "old-runner")
    }

    @Test("The pane lists Steam's prefixes beside the games Cartouche installed or runs from a store")
    func paneListsAllSources() async throws {
        let s = try scene("game-prefixes-pane")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let library = SteamLibrary(root: s.work.appending(path: "steam"))
        try FileManager.default.createDirectory(
            at: library.compatdata.appending(path: "1574480/pfx/drive_c"), withIntermediateDirectories: true)

        let model = PrefixesModel(libraries: { [library] }, installedTools: { [] }, games: games(s))
        await model.load()

        #expect(model.prefixes.count == 3)
        #expect(Set(model.prefixes.map(\.source)) == [.steam, .installer, .store(.epic)])
        let installer = try #require(model.prefixes.first { $0.source == .installer })
        #expect(model.lastTool(installer) == "Cartouche Wine 26.3")
        #expect(!model.isStale(installer))
        #expect(Set(model.usage.keys) == Set(model.prefixes.map(\.id)))
    }

    @Test("Only Steam's prefixes rebuild; an installer game's prefix is never deleted; a store game's has no tools here")
    func actionsPerSource() throws {
        let library = SteamLibrary(root: URL(filePath: "/tmp/steam"))
        let steam = WinePrefix(appID: "1", name: "S", library: library, lastUsed: nil)
        let installer = WinePrefix(appID: "i", name: "I", library: library, lastUsed: nil,
                                   source: .installer, folder: URL(filePath: "/tmp/installs/i"))
        let store = WinePrefix(appID: "e", name: "E", library: library, lastUsed: nil,
                               source: .store(.gog), folder: URL(filePath: "/tmp/stores/gog/e"))
        #expect(steam.canRebuild && steam.canDelete && steam.canRunTools)
        #expect(!installer.canRebuild && !installer.canDelete && installer.canRunTools)
        #expect(!store.canRebuild && store.canDelete && !store.canRunTools)
        #expect(installer.root.path == "/tmp/installs/i")
        #expect(installer.pfx.path == "/tmp/installs/i/pfx")
        #expect(steam.root == library.compatdata.appending(path: "1"))
    }

    @Test("Deleting an installer game's prefix is refused and leaves the game whole")
    func installerDeleteRefused() async throws {
        let s = try scene("game-prefixes-delete-installer")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let model = PrefixesModel(libraries: { [] }, games: games(s))
        await model.load()
        let installer = try #require(model.prefixes.first { $0.source == .installer })

        #expect(throws: StepFailure.self) { try PrefixTools.delete(installer) }
        await model.delete([installer])

        #expect(model.failure?.contains("Uninstall") == true)
        #expect(model.outcome == nil)
        #expect(FileManager.default.fileExists(
            atPath: s.installer.appending(path: "pfx/drive_c/Games/Sample Quest/quest.exe").path(percentEncoded: false)))
        #expect(model.prefixes.contains { $0.id == installer.id })
    }

    @Test("Deleting a store game's prefix takes the prefix only; its record and folder stay")
    func storeDeleteKeepsRecord() async throws {
        let s = try scene("game-prefixes-delete-store")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let model = PrefixesModel(libraries: { [] }, games: games(s))
        await model.load()
        let store = try #require(model.prefixes.first { $0.source == .store(.epic) })

        await model.delete([store])

        #expect(model.failure == nil)
        #expect(model.outcome == "Deleted the prefix for Sample Free Game. Cartouche will make a new one the next time the game is played.")
        #expect(!FileManager.default.fileExists(atPath: s.store.appending(path: "pfx").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: s.store.path(percentEncoded: false)))
        #expect(s.stores.loadRecords(.epic).count == 1)
        #expect(!model.prefixes.contains { $0.id == store.id })
    }

    @Test("A rebuild asked for a game Cartouche made does nothing to it")
    func rebuildSkipsGames() async throws {
        let s = try scene("game-prefixes-rebuild")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let asked = Box(0)
        let tool = InstalledTool(tool: SupportedRunners.all[0].tools[0], build: SupportedRunners.all[0].id)
        let model = PrefixesModel(libraries: { [] }, installedTools: { [tool] },
                                  rebuild: { _, _, _ in asked.value += 1; return nil }, games: games(s))
        await model.load()

        await model.recreate(model.prefixes, as: tool)

        #expect(asked.value == 0)
        #expect(model.prefixes.count == 2)
    }

    @Test("An installer game's prefix backs up beside it and restores, game files included")
    func installerBackupRestores() async throws {
        let s = try scene("game-prefixes-backup")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let model = PrefixesModel(libraries: { [] }, games: games(s))
        await model.load()
        let installer = try #require(model.prefixes.first { $0.source == .installer })

        await model.backUp([installer])
        #expect(model.failure == nil)
        let backup = try #require(model.backups.first { $0.prefix.id == installer.id })
        #expect(backup.url.deletingLastPathComponent().standardizedFileURL.path == s.installer.standardizedFileURL.path)

        let save = s.installer.appending(path: "pfx/drive_c/Games/Sample Quest/save.dat")
        try Data("new".utf8).write(to: save)
        await model.restoreBackup(backup)

        #expect(model.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: save.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(
            atPath: s.installer.appending(path: "pfx/drive_c/Games/Sample Quest/quest.exe").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: s.installer.appending(path: "game.json").path(percentEncoded: false)))
    }

    @Test("A store game whose prefix is gone still lists its kept backups")
    func storeBackupOnly() throws {
        let s = try scene("game-prefixes-orphan")
        defer { try? FileManager.default.removeItem(at: s.work) }
        let fm = FileManager.default
        try fm.moveItem(at: s.store.appending(path: "pfx"), to: s.store.appending(path: "pfx.previous-20260101-120000"))

        let orphans = PrefixStore.games(installs: s.installs, stores: s.stores, live: false)
        #expect(orphans.map(\.title) == ["Sample Free Game"])
        #expect(PrefixStore.backupDetails(of: orphans[0]).count == 1)
    }

    @Test("Wine tools for an installer game use the Wine its own launcher exports")
    func toolsUseLauncherWine() throws {
        let work = try scratchDirectory("game-prefixes-launcher")
        defer { try? FileManager.default.removeItem(at: work) }
        let prefix = work.appending(path: "pfx")
        let wine = WineRunner(root: work.appending(path: "runner"), loader: work.appending(path: "runner/bin/wine"),
                              server: work.appending(path: "runner/bin/wineserver"), dllPath: "/dlls")
        let script = GameLauncher.script(exe: work.appending(path: "it's game.exe"), prefix: prefix, wine: wine)
        let exports = GameLauncher.exports(in: script)
        #expect(exports["WINELOADER"] == wine.loader.path(percentEncoded: false))
        #expect(exports["WINESERVER"] == wine.server.path(percentEncoded: false))
        #expect(exports["WINEPREFIX"] == prefix.path(percentEncoded: false))
        #expect(exports["PATH"] == nil)
        #expect(GameLauncher.exports(in: "export NAME='it'\\''s'\n") == ["NAME": "it's"])

        try Data(script.utf8).write(to: work.appending(path: "launch"))
        let game = WinePrefix(appID: "g", name: "G", library: SteamLibrary(root: work), lastUsed: nil,
                              source: .installer, folder: work)
        let found = try #require(PrefixTools.launcherWine(of: game))
        #expect(found.loader.path == wine.loader.path)
        #expect(found.server.path == wine.server.path)
        #expect(found.environment["WINEPREFIX"] == prefix.path(percentEncoded: false))
        #expect(found.environment["PATH"]?.hasPrefix(wine.root.path(percentEncoded: false) + "/bin:") == true)
        // The loader is not there: refused before anything runs.
        #expect(throws: StepFailure.self) { try PrefixTools.launch(.winecfg, in: game) }
        let store = WinePrefix(appID: "s", name: "S", library: SteamLibrary(root: work), lastUsed: nil,
                               source: .store(.epic), folder: work)
        #expect(throws: StepFailure.self) { try PrefixTools.launch(.winecfg, in: store) }
    }
}

// Crashes write their backtrace to the game's log and end the game, with no debugger window.
@Suite("Crash handling")
struct CrashHandlingTests {

    private func fakeWine(in work: URL) throws -> (WineRunner, URL) {
        let loader = work.appending(path: "wine")
        let server = work.appending(path: "wineserver")
        let log = work.appending(path: "calls")
        for file in [loader, server] {
            try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_LOG\"\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (WineRunner(root: work, loader: loader, server: server, dllPath: ""), log)
    }

    @Test("The registry turns off the crash dialog and keeps winedbg --auto for the backtrace, in both views")
    func registry() {
        let all = CrashHandling.registryArguments.map { $0.joined(separator: " ") }
        #expect(all.contains(#"reg add HKCU\Software\Wine\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0 /f"#))
        #expect(all.contains(#"reg add HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug /v Debugger /t REG_SZ /d winedbg --auto %ld %ld /f"#))
        #expect(all.contains(#"reg add HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug /v Auto /t REG_SZ /d 1 /f"#))
        #expect(all.filter { $0.hasSuffix("/reg:32") }.count == 2)
        // winedbg stays enabled: disabling it would lose the backtrace.
        #expect(!all.contains { $0.contains("winedbg.exe=d") })
    }

    @Test("An installer game's launcher sets the crash registry once per prefix, before the game starts")
    func launcherSetsRegistryOnce() async throws {
        let work = try scratchDirectory("crash-launcher")
        defer { try? FileManager.default.removeItem(at: work) }
        let (wine, log) = try fakeWine(in: work)
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let script = GameLauncher.script(exe: work.appending(path: "game.exe"), prefix: prefix, wine: wine)
        let crash = try #require(script.range(of: "cartouche-crash"))
        let exec = try #require(script.range(of: "\nexec "))
        #expect(crash.lowerBound < exec.lowerBound)
        let launch = work.appending(path: "launch")
        try Data(script.utf8).write(to: launch)

        let environment = ["FIXTURE_LOG": log.path, "PATH": "/usr/bin:/bin"]
        let first = try await offMain { try Shell.run("/bin/sh", [launch.path], environment: environment) }
        #expect(first.succeeded)
        var calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("reg add HKCU\\Software\\Wine\\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0 /f"))
        #expect(calls.contains("winedbg --auto %ld %ld"))
        #expect(try String(contentsOf: prefix.appending(path: CrashHandling.markerName), encoding: .utf8) == CrashHandling.version)

        try Data().write(to: log)
        _ = try await offMain { try Shell.run("/bin/sh", [launch.path], environment: environment) }
        calls = try String(contentsOf: log, encoding: .utf8)
        #expect(!calls.contains("reg add"))
        #expect(calls.contains("game.exe"))
    }

    @Test("A launcher written before crash handling gets it once, before the game starts")
    func olderLauncherGetsBlock() throws {
        let work = try scratchDirectory("crash-older-launcher")
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = GameFolder(root: work)
        let old = "#!/bin/sh\nexport WINELOADER='/w/wine'\nexport WINEPREFIX='/p'\ncd '/g' || exit 1\nexec '/w/wine' '/g/game.exe' \"$@\"\n"
        try Data(old.utf8).write(to: folder.launcher)

        try CrashHandling.addLauncherLines(to: folder)
        let text = try String(contentsOf: folder.launcher, encoding: .utf8)
        let crash = try #require(text.range(of: CrashHandling.markerName))
        let cd = try #require(text.range(of: "\ncd '/g'"))
        #expect(crash.lowerBound < cd.lowerBound)
        try CrashHandling.addLauncherLines(to: folder)
        #expect(try String(contentsOf: folder.launcher, encoding: .utf8) == text)

        // No exported loader to run reg with: left alone.
        let bare = "#!/bin/sh\ncd '/g' || exit 1\nexec wine game.exe\n"
        try Data(bare.utf8).write(to: folder.launcher)
        try CrashHandling.addLauncherLines(to: folder)
        #expect(try String(contentsOf: folder.launcher, encoding: .utf8) == bare)
    }

    @Test("A launcher whose registry write fails still starts the game and tries again next time")
    func launcherFailureStillStarts() async throws {
        let work = try scratchDirectory("crash-launcher-fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let (wine, log) = try fakeWine(in: work)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_LOG\"\ncase \"$1\" in reg) exit 1 ;; esac\n".utf8)
            .write(to: wine.loader)
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let launch = work.appending(path: "launch")
        try Data(GameLauncher.script(exe: work.appending(path: "game.exe"), prefix: prefix, wine: wine).utf8).write(to: launch)

        let result = try await offMain {
            try Shell.run("/bin/sh", [launch.path], environment: ["FIXTURE_LOG": log.path, "PATH": "/usr/bin:/bin"])
        }
        #expect(result.succeeded)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("game.exe"))
        #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: CrashHandling.markerName).path))
    }

    @Test("A store game's prefix gets the same registry once, before launch")
    func storeApplyOnce() async throws {
        let work = try scratchDirectory("crash-store")
        defer { try? FileManager.default.removeItem(at: work) }
        let (wine, log) = try fakeWine(in: work)
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let env = ["FIXTURE_LOG": log.path, "WINEPREFIX": prefix.path]

        try await offMain { CrashHandling.apply(wine: wine, prefix: prefix, environment: env) }
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == CrashHandling.registryArguments.count)
        try Data().write(to: log)
        try await offMain { CrashHandling.apply(wine: wine, prefix: prefix, environment: env) }
        #expect(try String(contentsOf: log, encoding: .utf8).isEmpty)
    }

    @Test("A crash's log is kept under its own name; a clean run's is not; only the newest few stay")
    func crashLogKept() throws {
        let work = try scratchDirectory("crash-log")
        defer { try? FileManager.default.removeItem(at: work) }
        let log = work.appending(path: CrashLog.gameLog)

        try Data("fixme:d3d:something\n".utf8).write(to: log)
        #expect(CrashLog.keep(log, in: work) == nil)

        try Data("Unhandled exception: page fault on read access to 0x00000000\nBacktrace:\n=>0 0x0040100a\n".utf8).write(to: log)
        let kept = try #require(CrashLog.keep(log, in: work, now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(kept.lastPathComponent.hasPrefix(CrashLog.namePrefix))
        #expect(CrashLog.latest(in: work) == kept)
        #expect(try String(contentsOf: kept, encoding: .utf8).contains("Backtrace:"))

        for day in 1...8 {
            CrashLog.keep(log, in: work, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
        }
        #expect(CrashLog.all(in: work).count == CrashLog.kept)
        let game = WinePrefix(appID: "g", name: "G", library: SteamLibrary(root: work), lastUsed: nil,
                              source: .installer, folder: work)
        #expect(PrefixLog.crash.url(for: game) == CrashLog.latest(in: work))
        #expect(PrefixLog.game.url(for: game) == log)
    }
}
