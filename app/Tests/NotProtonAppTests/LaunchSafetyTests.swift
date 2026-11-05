import Foundation
import InstallerKit
import Synchronization
import Testing
@testable import NotProtonApp

// T8: the folder's own answers — the one walk that finds DLSS and the anti-cheat marks,
// resolved before any launch writes its variables
@MainActor
@Suite("Launch safety: the folder's own answers")
struct LaunchSafetyTests {

    // A Steam game on the fixture's second library, the free Wine its resolution wants
    private func scene(_ label: String) async throws -> (fixture: SteamFixture, model: LibraryModel, game: Game) {
        let fixture = try SteamFixture(label)
        let runners = fixture.support.appending(path: "runners")
        let backends = fixture.support.appending(path: "backends")
        let free = try InstallerSetupTests.freeWine("wine-11.0", in: runners)
        try InstallerSetupTests.dxmt(in: backends)
        let model = libraryModel(fixture, running: false, defaults: ScratchDefaults())
        model.runners = [free]
        model.runnersFolder = runners
        model.backendsFolder = backends
        model.backendAvailability = BackendAvailability(d3dMetalRunners: [free.id], installed: [.dxmt],
                                                        crossOverWine: [free.id])
        await model.load()
        return (fixture, model, try #require(model.game("steam:730")))
    }

    private func env(_ model: LibraryModel, _ game: Game) -> [String: String] {
        model.resolution(for: game, choice: GameSetupChoice(graphics: .d3dmetal, translation: .rosetta)).setup.environment
    }

    @Test("An unlisted game with EasyAntiCheat_EOS.dll resolves protected: no frame generation, no HUD variables")
    func diskAntiCheatEAC() async throws {
        let (fixture, model, game) = try await scene("eac")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        try Data().write(to: folder.appending(path: "EasyAntiCheat_EOS.dll"))
        await model.scanGames([game])
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == "Easy Anti-Cheat")
        let e = env(model, game)
        for key in OverlayLaunch.variables { #expect(e[key] == nil, "\(key)") }
        #expect(e[LaunchProfile.consentVariable] == "0")
    }

    @Test("An unlisted game with BEClient_x64.dll resolves protected the same way")
    func diskAntiCheatBattlEye() async throws {
        let (fixture, model, game) = try await scene("battleye")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        try Data().write(to: folder.appending(path: "BEClient_x64.dll"))
        await model.scanGames([game])
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == "BattlEye")
        let e = env(model, game)
        for key in OverlayLaunch.variables { #expect(e[key] == nil, "\(key)") }
    }

    @Test("A clean folder resolves as before: unprotected, no frame generation by default, consent on file")
    func cleanGameUnchanged() async throws {
        let (fixture, model, game) = try await scene("clean")
        defer { fixture.remove() }
        await model.scanGames([game])
        let profile = model.launchProfile(for: game)
        #expect(!profile.protected && !profile.dlss)
        let e = env(model, game)
        #expect(e[FrameGeneration.variable] == nil && e["D3DM_ENABLE_METALFX"] == nil)
        #expect(e[OverlayLaunch.hudVariable] == "off")
        #expect(e[LaunchProfile.consentVariable] == "1")
    }

    @Test("Until the walk answers, an installed folder counts as protected")
    func unprovenFolderProtected() async throws {
        let (fixture, model, game) = try await scene("unproven")
        defer { fixture.remove() }
        #expect(model.launchProfile(for: game).protected)
        let e = env(model, game)
        for key in OverlayLaunch.variables { #expect(e[key] == nil, "\(key)") }
    }

    @Test("A Ubisoft game the base cannot name resolves protected under the generic name; a matched one shows its own")
    func ubisoftFailClosed() async throws {
        let (fixture, model, _) = try await scene("ubi-failclosed")
        defer { fixture.remove() }
        // No compat id, no folder, no scan: unknown is protected, never "no anti-cheat"
        let unknown = Game(id: "ubisoft:9001", source: .ubisoft, name: "Unmatched Game", installed: false)
        #expect(model.launchProfile(for: unknown).protected)
        #expect(model.antiCheatName(for: unknown) == ot("Anti-cheat"))
        // Matched by its compat app id: the real name, still protected
        model.antiCheat = { $0.compatAppID == 359550 ? "BattlEye" : nil }
        var siege = Game(id: "ubisoft:635", source: .ubisoft, name: "Matched Game", installed: false)
        siege.compatAppID = 359550
        #expect(model.launchProfile(for: siege).protected)
        #expect(model.antiCheatName(for: siege) == "BattlEye")
    }

    @Test("A runner move writes no frame generation for a protected game or a game without DLSS")
    func migrationNeverInjects() async throws {
        for mark in ["BEClient_x64.dll", nil] as [String?] {
            let work = try scratchDirectory("move-\(mark ?? "clean")")
            defer { try? FileManager.default.removeItem(at: work) }
            let installs = work.appending(path: "installs"), runners = work.appending(path: "runners")
            let backends = work.appending(path: "backends")
            try InstallerSetupTests.dxmt(in: backends)
            let old = try InstallerSetupTests.freeWine("wine-11.0", version: "11.0", in: runners)
            let new = try InstallerSetupTests.freeWine("wine-12.0", version: "12.0", in: runners)
            let folder = try InstallerSetupTests.installed(in: installs)
            if let mark {
                try Data().write(to: folder.prefix.appending(path: "drive_c/Games/Sample/\(mark)"))
            }
            let model = InstallerSetupTests.model(in: work, installs: installs, runners: [old, new],
                                                runnersFolder: runners, backends: backends)
            try await model.moveGames(from: old.id, to: new)
            let exports = GameLauncher.exports(in: try String(contentsOf: folder.launcher, encoding: .utf8))
            #expect(exports[FrameGeneration.variable] == nil && exports["D3DM_ENABLE_METALFX"] == nil,
                    Comment(rawValue: mark ?? "clean"))
            if mark != nil {
                for key in OverlayLaunch.variables where key != LaunchProfile.consentVariable {
                    #expect(exports[key] == nil, "\(key)")
                }
                #expect(exports[LaunchProfile.consentVariable] == "0")
            }
        }
    }

    @Test("A D3DM_ENABLE_METALFX left in the choice only reaches a game that ships DLSS")
    func metalFXResidual() async throws {
        let (fixture, model, game) = try await scene("metalfx-residual")
        defer { fixture.remove() }
        var choice = GameSetupChoice(graphics: .d3dmetal, translation: .rosetta)
        choice.environment = ["D3DM_ENABLE_METALFX": "1"]
        await model.scanGames([game])
        #expect(model.resolution(for: game, choice: choice).setup.environment["D3DM_ENABLE_METALFX"] == nil)
        let folder = try #require(model.installFolder(of: game))
        try Data().write(to: folder.appending(path: "nvngx_dlss.dll"))
        model.folderScans[game.id] = nil
        await model.scanGames([game])
        #expect(model.resolution(for: game, choice: choice).setup.environment["D3DM_ENABLE_METALFX"] == "1")
    }

    @Test("A runner move the new build cannot resolve drops MetalFX, unless the game ships DLSS")
    func migrationFallbackFilters() async throws {
        for dlss in [false, true] {
            let work = try scratchDirectory("move-fallback-\(dlss)")
            defer { try? FileManager.default.removeItem(at: work) }
            let installs = work.appending(path: "installs"), runners = work.appending(path: "runners")
            let backends = work.appending(path: "backends")
            try InstallerSetupTests.dxmt(in: backends)
            let old = try InstallerSetupTests.freeWine("wine-11.0", version: "11.0", in: runners)
            // A FEX-only build never enters installRunners, so the job falls back to the game's own variables
            let loader = WineRunnerInstaller.folder(for: "wine-12.0", runners: runners).appending(path: "bin/wine")
            try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: loader)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
            let new = Runner(id: "wine-12.0", kind: .wineBuild, version: "12.0", displayVersion: "12.0",
                             flavors: [.fex], state: .ready, build: nil, source: nil, isInstalled: true)
            let folder = try InstallerSetupTests.installed(in: installs)
            if dlss {
                try Data().write(to: folder.prefix.appending(path: "drive_c/Games/Sample/nvngx_dlss.dll"))
            }
            let model = InstallerSetupTests.model(in: work, installs: installs, runners: [old, new],
                                                runnersFolder: runners, backends: backends)
            let game = try #require(model.allGames.first { $0.source == .installer })
            var choice = model.setup(for: game.id)
            choice.environment = ["D3DM_ENABLE_METALFX": "1", "WINEMSYNC": "1"]
            model.setSetup(choice, for: game.id)
            try await model.moveGames(from: old.id, to: new)
            let exports = GameLauncher.exports(in: try String(contentsOf: folder.launcher, encoding: .utf8))
            #expect(exports["WINEMSYNC"] == "1", Comment(rawValue: "dlss=\(dlss)"))
            #expect(exports["D3DM_ENABLE_METALFX"] == (dlss ? "1" : nil), Comment(rawValue: "dlss=\(dlss)"))
        }
    }

    @Test("A launch never starts Steam on a stale environment it could not replace")
    func steamLaunchBlockedOnStaleEnv() async throws {
        let (fixture, model, game) = try await scene("stale-block")
        defer { fixture.remove() }
        let setups = model.setupsFolder
        try FileManager.default.createDirectory(at: setups, withIntermediateDirectories: true)
        let old = setups.appending(path: "730.env")
        try "CARTOUCHE_FRAMEGEN=1\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: setups.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setups.path(percentEncoded: false)) }
        var opened: [URL] = []
        let runner = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
        await runner.perform(.play, on: game)?.value
        #expect(!opened.contains { $0.absoluteString.contains("rungameid") })
        #expect(model.problem != nil)
    }

    @Test("A launch whose new file cannot land deletes the stale one instead of running on it")
    func steamLaunchDeletesStaleEnv() async throws {
        let (fixture, model, game) = try await scene("stale-delete")
        defer { fixture.remove() }
        let setups = model.setupsFolder
        // A directory in the file's place: the write fails, the removal succeeds, the launch is safe
        try FileManager.default.createDirectory(at: setups.appending(path: "730.env"), withIntermediateDirectories: true)
        var opened: [URL] = []
        model.framegenLaunched[game.id] = true
        let runner = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
        await runner.perform(.play, on: game)?.value
        #expect(opened.map(\.absoluteString) == ["steam://rungameid/730"])
        #expect(!FileManager.default.fileExists(atPath: setups.appending(path: "730.env").path(percentEncoded: false)))
        #expect(model.framegenLaunched[game.id] == false)
    }

    @Test("Refresh applies the same rule: the file it cannot rewrite leaves, and nothing is claimed")
    func steamRefreshDeletesStaleEnv() async throws {
        let (fixture, model, game) = try await scene("stale-refresh")
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: model.setupsFolder.appending(path: "730.env"),
                                                withIntermediateDirectories: true)
        model.framegenLaunched[game.id] = true
        await model.refreshSteamEnvironments()
        #expect(!FileManager.default.fileExists(
            atPath: model.setupsFolder.appending(path: "730.env").path(percentEncoded: false)))
        #expect(model.framegenLaunched[game.id] == false)
    }

    @Test("A saved profile purges the launch's STATS and INTERPOLATE leftovers")
    func profileSavedPurges() async throws {
        let (fixture, model, game) = try await scene("purge")
        defer { fixture.remove() }
        var choice = model.setup(for: game.id)
        choice.environment = ["CARTOUCHE_FRAMEGEN_STATS": "1", "CARTOUCHE_FRAMEGEN_INTERPOLATE": "0",
                              "CARTOUCHE_OVERLAY": "std", "WINEMSYNC": "1"]
        model.setSetup(choice, for: game.id)
        model.profileSaved(game.id)
        #expect(model.setup(for: game.id).environment == ["WINEMSYNC": "1"])
    }

    @Test("The folder walk runs off the main actor, once per game")
    func scanOffMainActor() async throws {
        let (fixture, model, game) = try await scene("offmain")
        defer { fixture.remove() }
        let seen = Mutex((calls: 0, onMain: false))
        model.folderScanner = { folder in
            let main = Thread.isMainThread
            seen.withLock { $0.calls += 1; $0.onMain = $0.onMain || main }
            return GameDiskScan.scan(in: folder)
        }
        await model.scanGames([game])
        #expect(model.folderScans[game.id] != nil)
        // The second launch and the profile read the cache: the walk happened once
        await model.scanGames([game])
        _ = model.launchProfile(for: game)
        let out = seen.withLock { $0 }
        #expect(out.calls == 1 && !out.onMain)
    }

    @Test("A second Play while the walk runs joins the first: the game launches once")
    func playOnceDuringWalk() async throws {
        let (fixture, model, game) = try await scene("play-once")
        defer { fixture.remove() }
        var opened: [URL] = []
        let runner = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
        let first = runner.perform(.play, on: game)
        // The app rebuilds its runner on every access: the guard lives in the model, not the runner
        let second = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
            .perform(.play, on: game)
        #expect(first != nil && second != nil)
        await first?.value
        await second?.value
        #expect(opened.map(\.absoluteString) == ["steam://rungameid/730"])
    }

    @Test("After loading, a DLSS+Temporal Steam game's written environment carries the library")
    func steamRefreshAfterScan() async throws {
        let (fixture, model, game) = try await scene("steam-dlss")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        try Data().write(to: folder.appending(path: "nvngx_dlss.dll"))
        // A choice written before the walk answered; the refresh must rewrite once it has
        model.setSetup(GameSetupChoice(graphics: .d3dmetal), for: game.id)
        await model.refreshSteamEnvironments()
        let lines = try String(contentsOf: model.setupsFolder.appending(path: "730.env"), encoding: .utf8)
        #expect(lines.contains("CARTOUCHE_FRAMEGEN=1"))
    }

    @Test("The same refresh keeps a marked game free of our variables")
    func steamRefreshMarked() async throws {
        let (fixture, model, game) = try await scene("steam-marked")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        try Data().write(to: folder.appending(path: "EasyAntiCheat_EOS.dll"))
        model.setSetup(GameSetupChoice(graphics: .d3dmetal), for: game.id)
        await model.refreshSteamEnvironments()
        let file = model.setupsFolder.appending(path: "730.env")
        let lines = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for key in OverlayLaunch.variables { #expect(!lines.contains(key), "\(key)") }
    }

    @Test("A walk cut at the entry limit resolves protected, under the generic name")
    func walkLimitProtected() async throws {
        let (fixture, model, game) = try await scene("limit")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        for i in 1...4 { try Data().write(to: folder.appending(path: "file\(i).bin")) }
        model.folderScanner = { GameDiskScan.scan(in: $0, limit: 2) }
        await model.scanGames([game])
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == ot("Anti-cheat"))
        let e = env(model, game)
        for key in OverlayLaunch.variables { #expect(e[key] == nil, "\(key)") }
    }

    @Test("A folder the walk cannot open resolves protected, under the generic name")
    func unreadableFolderProtected() async throws {
        let (fixture, model, game) = try await scene("unreadable")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        let path = folder.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        await model.scanGames([game])
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == ot("Anti-cheat"))
        let e = env(model, game)
        for key in OverlayLaunch.variables { #expect(e[key] == nil, "\(key)") }
    }

    @Test("A mark added after a clean walk re-walks at Play: protected, no launch variables written")
    func addedMarkRescanned() async throws {
        let (fixture, model, game) = try await scene("stale-mark")
        defer { fixture.remove() }
        let folder = try #require(model.installFolder(of: game))
        model.setSetup(GameSetupChoice(graphics: .d3dmetal), for: game.id)
        await model.scanGames([game])
        #expect(!model.launchProfile(for: game).protected)
        // The update landed between scans: an EAC mark the first walk never saw
        try Data().write(to: folder.appending(path: "EasyAntiCheat_EOS.dll"))
        var opened: [URL] = []
        let task = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
            .perform(.play, on: game)
        // The folder's stamp moved: Play waits on a new walk instead of trusting the cache
        #expect(task != nil)
        await task?.value
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == "Easy Anti-Cheat")
        #expect(opened.map(\.absoluteString) == ["steam://rungameid/730"])
        let lines = (try? String(contentsOf: model.setupsFolder.appending(path: "730.env"), encoding: .utf8)) ?? ""
        for key in OverlayLaunch.variables { #expect(!lines.contains(key), "\(key)") }
        #expect(!lines.contains("D3DM_ENABLE_METALFX"))
        #expect(model.framegenLaunched[game.id] != true)
    }

    @Test("A mark landing mid-walk still re-walks at Play: the stamp is read before the walk")
    func midWalkMarkRescanned() async throws {
        let (fixture, model, game) = try await scene("midwalk-mark")
        defer { fixture.remove() }
        model.setSetup(GameSetupChoice(graphics: .d3dmetal), for: game.id)
        let calls = Mutex(0)
        model.folderScanner = { folder in
            guard calls.withLock({ $0 += 1; return $0 == 1 }) else { return GameDiskScan.scan(in: folder) }
            // The update lands while the first walk runs, in a part it already passed
            try? Data().write(to: folder.appending(path: "EasyAntiCheat_EOS.dll"))
            return GameDiskScan(complete: true)
        }
        await model.scanGames([game])
        #expect(!model.launchProfile(for: game).protected)
        var opened: [URL] = []
        let task = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
            .perform(.play, on: game)
        // The folder moved under the walk: its old stamp fails, Play waits on a new walk
        #expect(task != nil)
        await task?.value
        #expect(calls.withLock { $0 } == 2)
        #expect(model.launchProfile(for: game).protected)
        #expect(model.antiCheatName(for: game) == "Easy Anti-Cheat")
        #expect(opened.map(\.absoluteString) == ["steam://rungameid/730"])
        let lines = (try? String(contentsOf: model.setupsFolder.appending(path: "730.env"), encoding: .utf8)) ?? ""
        for key in OverlayLaunch.variables { #expect(!lines.contains(key), "\(key)") }
        #expect(!lines.contains("D3DM_ENABLE_METALFX"))
        #expect(model.framegenLaunched[game.id] != true)
    }

    @Test("An unchanged stamp does not re-walk: Play launches on the cached answer")
    func sameStampNoRescan() async throws {
        let (fixture, model, game) = try await scene("same-stamp")
        defer { fixture.remove() }
        let calls = Mutex(0)
        model.folderScanner = { folder in
            calls.withLock { $0 += 1 }
            return GameDiskScan.scan(in: folder)
        }
        await model.scanGames([game])
        var opened: [URL] = []
        let task = GameActionRunner(model: model, open: { opened.append($0) }, activity: ActivityCenter())
            .perform(.play, on: game)
        #expect(task == nil)
        #expect(opened.map(\.absoluteString) == ["steam://rungameid/730"])
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Without the library in the game the HUD is Cartouche's own panel; with it, the game's")
    func hudOutsideByLoad() {
        let store = OverlayProfileStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "hud-\(UUID().uuidString)"))
        var game = OverlayGame(id: "g", name: "G", pid: 1)
        // Unknown launch state — a game started outside Cartouche — falls back to the native HUD
        #expect(OverlayCenter(game: game, store: store, soon: []).hudOutside)
        game.libraryLoaded = true
        #expect(!OverlayCenter(game: game, store: store, soon: []).hudOutside)
        // A protected game whose library already draws keeps that HUD: a second one doubled the FPS (488a93f9)
        game.antiCheat = "BattlEye"
        #expect(!OverlayCenter(game: game, store: store, soon: []).hudOutside)
    }
}
