import AppKit
import Foundation
import InstallerKit
import SwiftUI
import Testing

@testable import NotProtonApp

// A Unity game as it sits on an external drive: the program, its _Data folder, a crash handler and a runtime installer.
// Every program is the trap script: running any of them leaves a marker.
private func installedGame(in work: URL, trap: URL) throws -> URL {
    let game = work.appending(path: "Volumes/SSD/Disco Elysium")
    let fm = FileManager.default
    for dir in ["Disco Elysium_Data/Plugins/x86_64", "_CommonRedist/vcredist/2019"] {
        try fm.createDirectory(at: game.appending(path: dir), withIntermediateDirectories: true)
    }
    try Data().write(to: game.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll"))
    for exe in ["Disco Elysium.exe", "UnityCrashHandler64.exe", "_CommonRedist/vcredist/2019/VC_redist.x64.exe"] {
        let url = game.appending(path: exe)
        try Data("#!/bin/sh\ntouch '\(trap.path)'\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try FileHandle(forWritingTo: game.appending(path: "Disco Elysium.exe")).truncate(atOffset: 640_000)
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

    private func run(_ label: String, copy: Bool) async throws -> (FakeInstall, URL, InstallJob, VerbLog, [InstalledGame]) {
        let fake = try FakeInstall(label)
        let game = try installedGame(in: fake.work, trap: fake.trap)
        let verbs = VerbLog()
        let center = InstallCenter(engine: fake.engine(winetricks: verbs), notifier: RecordingNotifier())
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
        #expect(fake.calledWith() == ["x86_64 wineboot --init TEMP="])
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
        #expect(verbs.calls == [["vcrun2022"]])

        let record = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(ready.map(\.id) == [record.id])
        #expect(record.exe == game.appending(path: "Disco Elysium.exe").path)
        #expect(record.gameFolder == game.path)
        #expect(record.prefix.hasPrefix(fake.installs.path))
        #expect(!game.path.hasPrefix(fake.installs.path))
        let launcher = try String(contentsOf: record.launcher, encoding: .utf8)
        #expect(launcher.contains(GameLauncher.quote(game.appending(path: "Disco Elysium.exe").path)))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll").path))
    }

    @Test("Copied: the files land in the prefix, the program path follows, the original stays")
    func copied() async throws {
        let (fake, game, job, _, _) = try await run("import-copy", copy: true)
        #expect(job.phase == .ready)
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        let copy = URL(filePath: record.prefix).appending(path: "drive_c/Games/Disco Elysium")
        #expect(record.exe == copy.appending(path: "Disco Elysium.exe").path)
        #expect(record.gameFolder == nil)
        #expect(job.progress.bytes == DroppedFolder.size(of: game))
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "Disco Elysium_Data/Plugins/x86_64/steam_api64.dll").path))
        #expect(FileManager.default.fileExists(atPath: game.appending(path: "Disco Elysium.exe").path))
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))
    }
}
