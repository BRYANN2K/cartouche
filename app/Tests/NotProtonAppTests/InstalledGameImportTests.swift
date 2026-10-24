import AppKit
import Foundation
import InstallerKit
import SwiftUI
import Testing

@testable import NotProtonApp

// A Unity game as it sits on an external drive: a PE program that needs the 2015+ Visual C++
// runtime, its _Data folder, a crash handler and a generic _CommonRedist the import must ignore.
// The non-main programs are the trap script: running any of them leaves a marker.
private func installedGame(in work: URL, trap: URL) throws -> URL {
    let game = work.appending(path: "Volumes/SSD/Disco Elysium")
    let fm = FileManager.default
    for dir in ["Disco Elysium_Data/Plugins/x86_64", "_CommonRedist/vcredist/2019"] {
        try fm.createDirectory(at: game.appending(path: dir), withIntermediateDirectories: true)
    }
    try Data().write(to: game.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll"))
    let main = game.appending(path: "Disco Elysium.exe")
    try TestPE.build(imports: ["KERNEL32.dll", "MSVCP140.dll", "xinput1_3.dll"]).write(to: main)
    try FileHandle(forWritingTo: main).truncate(atOffset: 640_000)
    for exe in ["UnityCrashHandler64.exe", "_CommonRedist/vcredist/2019/VC_redist.x64.exe",
                "_CommonRedist/dxwebsetup.exe", "_CommonRedist/dotNetFx40_Full_setup.exe", "_CommonRedist/oalinst.exe"] {
        let url = game.appending(path: exe)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch '\(trap.path)'\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return game
}

@MainActor
private func importCenter(_ label: String) throws -> (InstallCenter, URL, URL) {
    let work = try scratchDirectory(label)
    let trap = work.appending(path: "trap-fired")
    let game = try installedGame(in: work, trap: trap)
    let center = InstallCenter(engine: InstallEngine(installs: work.appending(path: "installs"), runners: work.appending(path: "runners"),
                                                     registry: { RunnerRegistry() }),
                               notifier: RecordingNotifier())
    center.compat = { try? CompatFixture.data() }
    center.sheet.tool = { work.appending(path: "no-innoextract").path }
    center.sheet.loadRunners = { [] }
    center.sheet.isExternal = { _ in true }
    return (center, game, trap)
}

@MainActor
@Suite("Installed game import", .serialized)
struct InstalledGameImportTests {

    @Test("An installed game shows one green row and its match, no installer rows")
    func analysis() async throws {
        let (center, game, _) = try importCenter("import-analysis")
        center.open([game])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        let items = center.sheet.items
        #expect(items.map(\.title) == ["Installed game, ready to import", "Identified as Disco Elysium"])
        #expect(items[0].check == .ok)
        #expect(items[1].cover == 632_470)
        #expect(center.sheet.isImport)
        #expect(center.sheet.canContinue)
        #expect(center.sheet.analysis?.scan.setup == nil)
    }

    @Test("The review picks the game's program, uses the folder in place and builds an import, never a setup run")
    func review() async throws {
        let (center, game, trap) = try importCenter("import-review")
        center.open([game])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        center.sheet.toReview()
        #expect(center.sheet.step == .review)
        let exe = game.appending(path: "Disco Elysium.exe").standardizedFileURL.path
        #expect(center.sheet.programs?.candidates.map(\.path) == [exe])
        #expect(center.sheet.chosenExe == exe)
        #expect(center.sheet.storage == .inPlace)
        #expect(center.sheet.onExternalDrive)
        #expect(!center.sheet.canInstall)

        center.sheet.runnerID = "r"
        center.sheet.showInSteam = false
        #expect(center.sheet.canInstall)
        center.sheet.install()
        let job = try #require(center.sheet.job)
        let plan = try #require(job.request.importing)
        #expect(plan.folder.standardizedFileURL.path == game.standardizedFileURL.path)
        #expect(plan.exe.path == exe)
        #expect(!plan.copy && !plan.showInSteam)
        #expect(job.request.installerFiles.isEmpty)
        #expect(job.request.name == "Disco Elysium")
        #expect(await waitFor { job.phase == .failed })
        #expect(!FileManager.default.fileExists(atPath: trap.path))

        // Nothing of the game is offered for cleanup.
        center.sheet.confirmCleanup()
        #expect(center.sheet.cleanup == .idle)
        #expect(FileManager.default.fileExists(atPath: exe))
    }

    @Test("The drop sheet's program and storage reach the import: the review shows them and the job uses them")
    func dropChoicesHandOff() async throws {
        let (center, game, _) = try importCenter("import-handoff")
        let exe = game.appending(path: "Disco Elysium.exe").standardizedFileURL.path
        let returned = Box(0)
        center.open([game], decided: InstallSheetModel.Decided(exe: URL(filePath: exe), storage: .copy), back: { returned.value += 1 })
        #expect(await waitFor { center.sheet.step == .review })
        #expect(center.sheet.skippedAnalysis)
        #expect(center.sheet.decided != nil)
        #expect(center.sheet.chosenExe == exe)
        #expect(center.sheet.storage == .copy)

        let texts = try await renderedTexts(InstallSheet(center: center), size: CGSize(width: 620, height: 640),
                                            named: "import-handoff-review")
        #expect(seen(texts, "Starts with"))
        #expect(seen(texts, "Disco Elysium.exe"))
        #expect(seen(texts, "Copy into Cartouche"))
        #expect(seen(texts, "Change"))
        #expect(!seen(texts, "Which file starts the game?"))

        center.sheet.runnerID = "r"
        center.sheet.showInSteam = false
        #expect(center.sheet.canInstall)
        center.sheet.install()
        let job = try #require(center.sheet.job)
        let plan = try #require(job.request.importing)
        #expect(plan.exe.path == exe)
        #expect(plan.copy)
        #expect(await waitFor { !job.isRunning && job.phase != .waiting })
        #expect(returned.value == 0)
    }

    @Test("Back from a review the drop sheet decided returns to Add Games; Change asks again")
    func dropChoicesBack() async throws {
        let (center, game, _) = try importCenter("import-handoff-back")
        let exe = game.appending(path: "Disco Elysium.exe")
        let returned = Box(0)
        center.open([game], decided: InstallSheetModel.Decided(exe: exe, storage: .inPlace), back: { returned.value += 1 })
        #expect(await waitFor { center.sheet.step == .review })
        center.sheet.changeChoices()
        #expect(center.sheet.decided == nil)
        #expect(center.sheet.chosenExe == exe.standardizedFileURL.path)
        center.sheet.back()
        #expect(!center.isSheetPresented)
        center.sheetDismissed()
        #expect(returned.value == 1)
        #expect(center.sheet.step == .drop)

        // A program the folder no longer lists is asked for again, from the analysis
        center.open([game], decided: InstallSheetModel.Decided(exe: game.appending(path: "Gone.exe"), storage: .inPlace), back: { returned.value += 1 })
        #expect(await waitFor { center.sheet.analysis != nil && !center.sheet.isAnalyzing })
        #expect(center.sheet.decided == nil)
        #expect(center.sheet.step == .analysis)
        #expect(center.sheet.chosenExe == exe.standardizedFileURL.path)
    }

    @Test("The noisy SteamRIP folder is named by Unity's app.info and matched in the index")
    func engineInfoIdentifies() async throws {
        let (center, _, _) = try importCenter("import-engine-info")
        var json = try #require(JSONSerialization.jsonObject(with: Data(CompatFixture.json().utf8)) as? [String: Any])
        var records = json["records"] as? [String: Any] ?? [:]
        records["9999999"] = ["name": "Hollow Knight: Silksong"]
        json["records"] = records
        center.compat = { try? JSONDecoder().decode(CompatData.self, from: JSONSerialization.data(withJSONObject: json)) }

        let root = try scratchDirectory("import-engine-info-game").appending(path: "Hollow-Knight-Silksong-SteamRIP.com")
        for path in ["Hollow Knight Silksong/Hollow Knight Silksong.exe",
                     "Hollow Knight Silksong/UnityCrashHandler64.exe",
                     "_CommonRedist/dxwebsetup.exe"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Hollow Knight Silksong/Hollow Knight Silksong_Data"), withIntermediateDirectories: true)
        try Data("Team Cherry\nHollow Knight Silksong\n".utf8)
            .write(to: root.appending(path: "Hollow Knight Silksong/Hollow Knight Silksong_Data/app.info"))
        try Data("x".utf8).write(to: root.appending(path: "Read_Me_Instructions.txt"))

        center.open([root])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        #expect(center.sheet.isImport)
        #expect(center.sheet.gameName == "Hollow Knight: Silksong")
        #expect(center.sheet.appID == 9_999_999)
    }

    @Test("When the index misses, the Steam store lookup names the same candidates")
    func storeFallbackIdentifies() async throws {
        let (center, _, _) = try importCenter("import-store-lookup")
        let root = try scratchDirectory("import-store-lookup-game").appending(path: "Hollow-Knight-Silksong-SteamRIP.com")
        for path in ["Hollow Knight Silksong/Hollow Knight Silksong.exe", "_CommonRedist/dxwebsetup.exe"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Hollow Knight Silksong/Hollow Knight Silksong_Data"), withIntermediateDirectories: true)
        try Data("Team Cherry\nHollow Knight Silksong\n".utf8)
            .write(to: root.appending(path: "Hollow Knight Silksong/Hollow Knight Silksong_Data/app.info"))

        var lookup = SteamLookup(directory: root.deletingLastPathComponent().appending(path: "lookup"))
        lookup.fetch = { _ in
            let body = try JSONSerialization.data(withJSONObject: [
                "total": 1, "items": [["id": 9_999_999, "type": "app", "name": "Hollow Knight: Silksong"]],
            ])
            return (body, 200)
        }
        center.lookup = lookup
        center.lookupsAllowed = { true }

        center.open([root])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        #expect(center.sheet.gameName == "Hollow Knight: Silksong")
        #expect(center.sheet.appID == 9_999_999)
        #expect(center.sheet.identificationViaSteam)
    }

    @Test("A folder with only data and no program blocks Continue")
    func noProgram() async throws {
        let (center, _, _) = try importCenter("import-empty")
        let folder = try scratchDirectory("import-empty-game")
        try FileManager.default.createDirectory(at: folder.appending(path: "Game_Data"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Game_Data/steam_api64.dll"))
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        #expect(center.sheet.isImport)
        #expect(center.sheet.items.first?.check == .failed)
        #expect(!center.sheet.canContinue)
        #expect(center.sheet.hasBlockingProblem)
    }

    @Test("The import steps render in light and dark")
    func snapshots() async throws {
        _ = NSApplication.shared
        let (center, game, _) = try importCenter("import-snap")
        let out = try ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"].map { URL(filePath: $0) } ?? scratchDirectory("snapshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shoot(_ name: String) throws {
            for (scheme, label) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let host = NSHostingView(rootView: InstallSheet(center: center)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appending(path: "installer-\(name)-\(label).png"))
                #expect(host.bounds.width > 400)
            }
        }
        center.open([game])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        try shoot("import-2-analysis")
        center.sheet.toReview()
        try shoot("import-3-review")
    }
}

@MainActor
@Suite("Installed game import flow", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct InstalledGameImportFlowTests {

    private func run(_ label: String, copy: Bool, staging: URL? = nil) async throws -> (FakeInstall, URL, InstallJob, VerbLog, [InstalledGame]) {
        let fake = try FakeInstall(label)
        var game = try installedGame(in: fake.work, trap: fake.trap)
        let verbs = VerbLog()
        var engine = fake.engine(winetricks: verbs)
        if let staging {
            // Where a dropped archive lands once extracted
            let extracted = staging.appending(path: "Disco Elysium Archive/Disco Elysium")
            try FileManager.default.createDirectory(at: extracted.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: game, to: extracted)
            game = extracted
            engine.dropStaging = staging
        }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        var ready: [InstalledGame] = []
        center.onGameReady = { ready.append($0) }
        var request = InstallRequest(setup: game, source: game, name: "Disco Elysium", appID: 632_470, gogID: nil,
                                     expectedBytes: copy ? DroppedFolder.size(of: game) : 0, installerBytes: 0, installerFiles: [], manifest: nil)
        request.importing = GameImport(folder: game, exe: game.appending(path: "Disco Elysium.exe"), copy: copy, showInSteam: false)
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Disco Elysium"))
        center.enqueue(job)
        #expect(await waitFor { job.phase == .ready || job.phase == .failed })
        return (fake, game, job, verbs, ready)
    }

    @Test("Used in place: a new prefix and the runtimes, the game's folder untouched and recorded as the user's")
    func inPlace() async throws {
        let (fake, game, job, verbs, ready) = try await run("import-in-place", copy: false)
        #expect(job.phase == .ready)
        #expect(fake.calledWith() == ["x86_64 wineboot -u TEMP="])
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
        // The PE imports asked for vcrun2022; the generic _CommonRedist (DirectX, .NET, OpenAL) was ignored.
        #expect(verbs.calls == [["vcrun2022"]])
        #expect(job.runtimeSteps.map(\.status) == [.installed])

        let record = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(ready.map(\.id) == [record.id])
        #expect(record.exe == game.appending(path: "Disco Elysium.exe").path)
        #expect(record.redistributables == ["vcrun2022"])
        #expect(record.gameFolder == game.path)
        #expect(record.prefix.hasPrefix(fake.installs.path))
        #expect(!game.path.hasPrefix(fake.installs.path))
        let launcher = try String(contentsOf: record.launcher, encoding: .utf8)
        #expect(launcher.contains(GameLauncher.quote(game.appending(path: "Disco Elysium.exe").path)))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll").path))
    }

    @Test("Copied: the files land in the prefix, the program path follows, the original stays")
    func copied() async throws {
        let (fake, game, job, verbs, _) = try await run("import-copy", copy: true)
        #expect(job.phase == .ready)
        #expect(verbs.calls == [["vcrun2022"]])
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        let copy = URL(filePath: record.prefix).appending(path: "drive_c/Games/Disco Elysium")
        #expect(record.exe == copy.appending(path: "Disco Elysium.exe").path)
        #expect(record.gameFolder == nil)
        #expect(job.progress.bytes == DroppedFolder.size(of: game))
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll").path))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "Disco Elysium.exe").path))
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
    }

    @Test("Extracted from a dropped archive and used in place: the game moves out of Caches into its prefix",
          arguments: [false, true])
    func extractedArchive(copy: Bool) async throws {
        let staging = try scratchDirectory("import-staged-root").appending(path: "Library/Caches/Cartouche/DropStaging")
        let (fake, game, job, verbs, _) = try await run("import-staged-\(copy)", copy: copy, staging: staging)
        #expect(job.phase == .ready)
        #expect(verbs.calls == [["vcrun2022"]])
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        let home = URL(filePath: record.prefix).appending(path: "drive_c/Games/Disco Elysium")
        #expect(record.exe == home.appending(path: "Disco Elysium.exe").path)
        #expect(record.gameFolder == nil)
        #expect(!record.exe.contains("/Library/Caches/"))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll").path))
        #expect(!FileManager.default.fileExists(atPath: game.path), "nothing of the game is left in the staging")
        // The emptied archive folder is cleared once the record is written
        #expect(await waitFor { !FileManager.default.fileExists(atPath: game.deletingLastPathComponent().path) })
        let launcher = try String(contentsOf: record.launcher, encoding: .utf8)
        #expect(launcher.contains(GameLauncher.quote(home.appending(path: "Disco Elysium.exe").path)))
        #expect(!launcher.contains(staging.path))
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
    }

    private func hangingJob(
        _ label: String, imports: [String] = ["KERNEL32.dll", "MSVCP140.dll", "xinput1_3.dll"], verbs: VerbLog
    ) async throws -> (FakeInstall, InstallCenter, InstallJob) {
        let fake = try FakeInstall(label)
        let game = try installedGame(in: fake.work, trap: fake.trap)
        try TestPE.build(imports: imports).write(to: game.appending(path: "Disco Elysium.exe"))
        var engine = fake.engine(winetricks: verbs)
        engine.verbTimeout = 0.5
        engine.winetricks = { calls, _, _, _ in
            verbs.add(calls)
            let hang = verbs.calls.count == 1
            return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: ["-c", hang ? "sleep 30" : "exit 0"], environment: [:]))
        }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        var request = InstallRequest(setup: game, source: game, name: "Disco Elysium", appID: nil, gogID: nil,
                                     expectedBytes: 0, installerBytes: 0, installerFiles: [], manifest: nil)
        request.importing = GameImport(folder: game, exe: game.appending(path: "Disco Elysium.exe"), copy: false, showInSteam: false)
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Disco Elysium"))
        center.enqueue(job)
        return (fake, center, job)
    }

    @Test("A runtime that stalls is killed after the timeout and skipped, and the import finishes")
    func verbTimeout() async throws {
        let (fake, _, job) = try await hangingJob("import-verb-timeout", verbs: VerbLog())
        #expect(await waitFor { job.phase == .ready }, "the import did not finish")
        #expect(job.runtimeSteps.map(\.status) == [.skipped])
        #expect(InstalledGames.all(in: fake.installs).first?.redistributables == [])
    }

    @Test("Skip abandons the current runtime and the next one still installs")
    func skipVerb() async throws {
        let verbs = VerbLog()
        let (_, center, job) = try await hangingJob("import-verb-skip", imports: ["MSVCP140.dll", "d3dx9_43.dll"], verbs: verbs)
        #expect(await waitFor { job.phase == .redistributables })
        center.sheet.show(job)
        center.sheet.skipRuntime()
        #expect(await waitFor { job.phase == .ready })
        #expect(verbs.calls == [["vcrun2022"], ["d3dx9"]])
        #expect(job.runtimeSteps.map(\.status) == [.skipped, .installed])
    }
}
