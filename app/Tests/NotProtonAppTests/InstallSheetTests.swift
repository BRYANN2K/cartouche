import AppKit
import Foundation
import InstallerKit
import SwiftUI
import Testing

@testable import NotProtonApp

// innoextract's recorded answers for an Inno Setup 5.5 installer with heavy decompression.
private let innoInfo = """
Inspecting "Disco Elysium" - setup data version 5.5.0.1 (unicode)

Languages:
 - en: English
 - russian: Русский

Setup is not passworded!
"""
private let innoList = "tmp/unarc.dll\ntmp/ISDone.dll\ntmp/cls-srep_x64.exe\napp/game.exe\napp/_Redist/dxwebsetup.exe\n"

// md5 of "a" and "b"
private let sums = "; some parts are optional downloads\r\n0cc175b9c0f1b6a831c399e269772661 *..\\data-01.bin\r\n92eb5ffee6ae2fec3ad71c777531578f *..\\data-02.bin\r\n"

@MainActor
func sheetFixture(_ label: String, manifest: String = sums.replacingOccurrences(of: "some parts are optional downloads", with: "checksums"),
                  parts: [String: String] = ["data-01.bin": "a", "data-02.bin": "b"]) throws -> (InstallCenter, URL) {
    let work = try scratchDirectory(label)
    let folder = work.appending(path: "Sample Game Installer")
    try FileManager.default.createDirectory(at: folder.appending(path: "MD5"), withIntermediateDirectories: true)
    try Data("MZ".utf8).write(to: folder.appending(path: "setup.exe"))
    for (name, content) in parts { try Data(content.utf8).write(to: folder.appending(path: name)) }
    try Data(manifest.utf8).write(to: folder.appending(path: "MD5/checksums.md5"))

    let tool = work.appending(path: "innoextract")
    try Data("#!/bin/sh\nif [ \"$1\" = --info ]; then cat <<'EOF'\n\(innoInfo)\nEOF\nelse cat <<'EOF'\n\(innoList)EOF\nfi\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

    let center = InstallCenter(engine: InstallEngine(installs: work.appending(path: "installs"), runners: work.appending(path: "runners"),
                                                     registry: { RunnerRegistry() }),
                               notifier: RecordingNotifier())
    center.compat = { try? CompatFixture.data() }
    center.sheet.tool = { tool.path }
    center.sheet.loadRunners = { [] }
    return (center, folder)
}

@MainActor
@Suite("Install sheet", .serialized)
struct InstallSheetTests {

    @Test("A two-part Inno installer: Inno Setup 5.5, 2 parts, heavy decompression, checksums OK, game identified")
    func multiPart() async throws {
        let (center, folder) = try sheetFixture("sheet-ok")
        center.open([folder])
        #expect(center.isSheetPresented)
        #expect(center.sheet.step == .analysis)
        #expect(await waitFor { !center.sheet.isAnalyzing })
        let items = center.sheet.items
        #expect(items.map(\.title) == ["Inno Setup 5.5 installer", "2 parts found", "Files are intact", "Identified as Disco Elysium", items.last!.title])
        #expect(items[0].detail.hasPrefix("With heavy decompression (unarc, isdone"))
        #expect(items[3].cover == 632_470)
        #expect(items.allSatisfy { $0.check != .failed })
        #expect(center.sheet.canContinue)
        #expect((center.sheet.analysis?.seconds ?? 99) < 30)
        center.sheet.toReview()
        #expect(center.sheet.step == .review)
    }

    @Test("A missing required part is named in red, Continue is disabled and Check Again is offered")
    func missingPart() async throws {
        let (center, folder) = try sheetFixture("sheet-missing", parts: ["data-01.bin": "a"])
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        let missing = try #require(center.sheet.items.first { $0.id == "parts" })
        #expect(missing.title == "data-02.bin is missing")
        #expect(missing.check == .failed)
        #expect(!center.sheet.canContinue)
        #expect(center.sheet.hasBlockingProblem)

        // Check Again after the file is back.
        try Data("b".utf8).write(to: folder.appending(path: "data-02.bin"))
        center.sheet.checkAgain()
        #expect(await waitFor { !center.sheet.isAnalyzing })
        #expect(center.sheet.canContinue)
    }

    @Test("A missing part the manifest calls optional is orange and Install stays possible")
    func optionalPart() async throws {
        let (center, folder) = try sheetFixture("sheet-optional", manifest: sums, parts: ["data-01.bin": "a"])
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        let optional = try #require(center.sheet.items.first { $0.id.hasPrefix("optional-") })
        #expect(optional.title == "data-02.bin is missing")
        #expect(optional.check == .warning)
        #expect(optional.detail.hasPrefix("It may be optional"))
        #expect(center.sheet.canContinue)
    }

    @Test("Picking another game in the review step switches the cover and the match")
    func correctMatch() async throws {
        let (center, folder) = try sheetFixture("sheet-correct")
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        center.sheet.toReview()
        #expect(center.sheet.appID == 632_470)
        center.sheet.search = "elden"
        let pick = try #require(center.sheet.results.first)
        center.sheet.pick(pick)
        #expect(center.sheet.appID == 1_245_620)
        #expect(center.sheet.gameName == "Elden Ring")
        #expect(center.sheet.identification?.source == .user)
        #expect(center.sheet.installDir == #"C:\Games\Elden Ring"#)
    }

    @Test("After a failed install, Close then Add Games starts again from the drop step")
    func failedThenAddGames() throws {
        let (center, folder) = try sheetFixture("failed-reopen")
        let request = InstallRequest(setup: folder.appending(path: "setup.exe"), source: folder, name: "G", appID: nil, gogID: nil,
                                     expectedBytes: 1, installerBytes: 1, installerFiles: [], manifest: nil)
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: "r", gameName: "G"))
        job.phase = .failed
        center.sheet.show(job)
        center.isSheetPresented = true
        center.sheet.close()
        center.open()
        #expect(center.sheet.step == .drop)
        #expect(center.sheet.job == nil)
    }

    @Test("Without a runner, Install is disabled")
    func noRunner() async throws {
        let (center, folder) = try sheetFixture("sheet-norunner")
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        center.sheet.toReview()
        #expect(!center.sheet.canInstall)
    }

    @Test("The sheet renders every step in light and dark")
    func snapshots() async throws {
        _ = NSApplication.shared
        let (center, folder) = try sheetFixture("sheet-snap")
        let out = try ProcessInfo.processInfo.environment["CARTOUCHE_SNAPSHOTS"].map { URL(filePath: $0) }
            ?? scratchDirectory("snapshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func shoot(_ name: String) throws {
            for (scheme, label) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let view = InstallSheet(center: center)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: out.appending(path: "installer-\(name)-\(label).png"))
                #expect(host.bounds.width > 400)
            }
        }

        try shoot("1-drop")
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        try shoot("2-analysis")
        center.sheet.toReview()
        try shoot("3-review")

        let fake = try FakeInstall("sheet-snap-run")
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Disco Elysium"))
        job.phase = .installing
        job.progress = InstallProgress(expected: 40 << 30)
        job.progress.bytes = 17 << 30; job.progress.fraction = 0.42; job.progress.bytesPerSecond = 142 * 1_048_576
        job.progress.secondsLeft = 1300; job.progress.cpu = 94
        center.sheet.show(job)
        try shoot("4-installing")
        job.progress.stuck = true
        try shoot("4b-stuck")
        job.progress.stuck = false
        job.phase = .failed
        job.diagnosis = InstallLog.diagnose(exitCode: 0, log: "Unarc.dll returned an error code: -11")
        try shoot("4c-failed")
        job.phase = .choosing
        job.installFolder = URL(filePath: "/G")
        job.candidates = ExeDetector.rank(exes: [("/G/game.exe", 60_000_000), ("/G/GameLauncher.exe", 5_000_000), ("/G/unins000.exe", 1)],
                                         shortcuts: ["/G/game.exe"])
        job.redistributables = [Redistributables.identify("_Redist/dxwebsetup.exe")!, Redistributables.identify("_Redist/VC_redist.x64.exe")!]
        job.redistributablesInstalled = true
        center.sheet.chosenExe = job.candidates.first?.path
        try shoot("5-exe")
        job.phase = .ready
        try shoot("6-ready")
    }
}
