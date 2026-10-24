import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

private func executable(_ url: URL, _ body: String) throws {
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
}

@MainActor
private func directJob(in work: URL) -> InstallJob {
    var request = InstallRequest(setup: work.appending(path: "setup.exe"), source: work,
                                 name: "Sample Game", appID: nil, gogID: nil, expectedBytes: 0,
                                 installerBytes: 0, installerFiles: [], manifest: nil)
    request.directUnpack = DirectUnpackPlan(parts: [], helpers: ["unarc.dll"], unarcModule: "unarc.dll",
                                            arcConfig: "arc.ini", clsConfig: nil, manifestPath: nil)
    var inputs = InstallInputs(runnerID: "runner", gameName: "Sample Game", mode: .automatic)
    inputs.applyUnpackerProfile(ramBytes: 16 << 30)
    return InstallJob(request: request, inputs: inputs)
}

// Fixes that need no Wine: they run on any Mac.
@MainActor
@Suite("Installer fallback and robustness")
struct InstallerFallbackTests {

    @Test("After a direct unpack fails, Try Again, a fix and the standard retry all switch to setup under Wine")
    func retriesUseStandardMethod() async throws {
        let work = try scratchDirectory("fallback-retry")
        let center = InstallCenter(engine: InstallEngine(installs: work.appending(path: "installs"),
                                                         runners: work.appending(path: "runners"),
                                                         registry: { RunnerRegistry() }),
                                   notifier: RecordingNotifier())
        let retries: [@MainActor (InstallJob) -> Void] = [
            { center.requeue($0) }, { center.retry($0, fixes: [.verifyFiles]) }, { center.retryStandard($0) },
        ]
        for retry in retries {
            let job = directJob(in: work)
            // A retry only runs a job the center holds; the runnerless engine fails it at once.
            center.enqueue(job)
            #expect(await waitFor { job.phase == .failed })
            job.directUnpackFailed = true
            retry(job)
            #expect(job.request.directUnpack == nil)
            #expect(job.inputs.mode == .guided)
            #expect(job.verificationFallback == 2)
            #expect(!job.directUnpackFailed)
            // The runnerless engine fails fast; the job stays on the standard method.
            #expect(await waitFor { job.phase == .failed })
            #expect(job.request.directUnpack == nil)
        }
    }

    @Test("A plain failure that was not a direct unpack keeps its method on Try Again")
    func plainRequeueKeepsMethod() async throws {
        let work = try scratchDirectory("fallback-plain")
        let center = InstallCenter(engine: InstallEngine(installs: work.appending(path: "installs"),
                                                         runners: work.appending(path: "runners"),
                                                         registry: { RunnerRegistry() }),
                                   notifier: RecordingNotifier())
        let job = directJob(in: work)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        center.requeue(job)
        #expect(job.request.directUnpack != nil)
        #expect(job.verificationFallback == 0)
        #expect(await waitFor { job.phase == .failed })
    }

    @Test("The app section merges into the unpacked tree: shared folders keep their unpacked files")
    func mergeKeepsUnpackedFolders() throws {
        let work = try scratchDirectory("merge-tree")
        let fm = FileManager.default
        let unpacked = work.appending(path: "game"), section = work.appending(path: "app")
        for (root, files) in [(unpacked, ["_Redist/vcredist.exe": "unpacked", "bin/game.exe": "game", "bin/shared.dll": "old"]),
                              (section, ["_Redist/game.md5": "sums", "bin/shared.dll": "new", "readme.txt": "hi"])] {
            for (path, content) in files {
                let url = root.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url)
            }
        }
        try InstallEngine.mergeContents(of: section, into: unpacked)
        let read = { (path: String) in try? String(contentsOf: unpacked.appending(path: path), encoding: .utf8) }
        #expect(read("_Redist/vcredist.exe") == "unpacked")
        #expect(read("_Redist/game.md5") == "sums")
        #expect(read("bin/game.exe") == "game")
        #expect(read("bin/shared.dll") == "new")
        #expect(read("readme.txt") == "hi")
        // The source is copied, never moved.
        #expect(fm.fileExists(atPath: section.appending(path: "bin/shared.dll").path(percentEncoded: false)))
    }

    @Test("Variants of one path are one entry: any variant's size passes, a missing variant is not damage")
    func scriptVariants() async throws {
        let files = GameVerify.installedFiles(from: [
            InnoFileEntry(path: #"app\voice.pak"#, bytes: 100),
            InnoFileEntry(path: #"app\voice.pak"#, bytes: 200),
            InnoFileEntry(path: #"APP\Voice.pak"#, bytes: 200),
            InnoFileEntry(path: #"app\intro_de.bik"#, bytes: 7),
            InnoFileEntry(path: #"app\intro_de.bik"#, bytes: 8),
            InnoFileEntry(path: #"app\game.exe"#, bytes: 5),
        ])
        #expect(files == [
            VerificationFile(path: "voice.pak", bytes: 100, variants: [100, 200]),
            VerificationFile(path: "intro_de.bik", bytes: 7, variants: [7, 8]),
            VerificationFile(path: "game.exe", bytes: 5),
        ])

        let dir = try scratchDirectory("ov-variants")
        try Data(repeating: 1, count: 200).write(to: dir.appending(path: "voice.pak"))
        try Data("12345".utf8).write(to: dir.appending(path: "game.exe"))
        #expect(try await GameVerify.checkSizes(files, root: dir).isEmpty)

        try Data(repeating: 1, count: 150).write(to: dir.appending(path: "voice.pak"))
        try FileManager.default.removeItem(at: dir.appending(path: "game.exe"))
        #expect(try await GameVerify.checkSizes(files, root: dir) == ["game.exe", "voice.pak"])
    }

    @Test("A file list saved before variants existed still decodes")
    func verificationFileDecodesOldRecords() throws {
        let old = try JSONDecoder().decode(VerificationFile.self, from: Data(#"{"path":"game.exe","bytes":5}"#.utf8))
        #expect(old == VerificationFile(path: "game.exe", bytes: 5))
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!encoded.contains("variants"))
    }

    @Test("A fresh attempt skips folders another job holds, even unfinished ones")
    func heldFolderIsNotTaken() throws {
        let installs = try scratchDirectory("held-folder")
        let first = try GameFolder.fresh(for: "Sample", in: installs)
        let second = try GameFolder.fresh(for: "Sample", in: installs, held: [first.root.lastPathComponent])
        #expect(second.root.lastPathComponent == "sample-2")
        #expect(FileManager.default.fileExists(atPath: first.attempt.path(percentEncoded: false)))
        // Without the hold, an unfinished attempt is still cleared for its own retry.
        let retry = try GameFolder.fresh(for: "Sample", in: installs)
        #expect(retry.root == first.root)
    }

    @Test("Cancel ends a running tool at once and refuses later runs")
    func cancellableTool() async throws {
        let work = try scratchDirectory("tool-cancel")
        let tool = work.appending(path: "slow-tool")
        try executable(tool, "sleep 30")
        let runner = CancellableToolRunner(timeout: 60)
        let path = tool.path(percentEncoded: false)
        let start = Date()
        let run = Task.detached { () -> Bool in
            do { _ = try runner.run(path, []); return false } catch is CancellationError { return true } catch { return false }
        }
        try await Task.sleep(for: .milliseconds(300))
        runner.cancel()
        #expect(await run.value)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(throws: CancellationError.self) { try runner.run(path, []) }

        let quick = CancellableToolRunner(timeout: 10)
        #expect(try quick.run("/bin/echo", ["ok"]) == "ok\n")
    }

    @Test("The cleanup confirmation names the files, and counts the rest of a long parts list")
    func cleanupNamesFiles() throws {
        let work = try scratchDirectory("cleanup-names")
        let source = work.appending(path: "Sample Game")
        func job(parts: Int) -> InstallJob {
            let files = [source.appending(path: "setup.exe")]
                + (1...parts).map { source.appending(path: String(format: "data-%02d.bin", $0)) }
                + [source.appending(path: "MD5/checksums.md5")]
            let request = InstallRequest(setup: files[0], source: source, name: "Sample Game", appID: nil, gogID: nil,
                                         expectedBytes: 1, installerBytes: 1, installerFiles: files, manifest: nil)
            return InstallJob(request: request, inputs: InstallInputs(runnerID: "r", gameName: "Sample Game"))
        }
        let sheet = InstallSheetModel()
        sheet.show(job(parts: 2))
        #expect(sheet.cleanupNames == ["setup.exe", "data-01.bin", "data-02.bin", "MD5/checksums.md5"])
        for name in sheet.cleanupNames { #expect(sheet.cleanupMessage.contains(name)) }

        sheet.show(job(parts: 20))
        #expect(sheet.cleanupNames.count == 22)
        #expect(sheet.cleanupMessage.contains("setup.exe"))
        #expect(sheet.cleanupMessage.contains("14 more files"))
        #expect(!sheet.cleanupMessage.contains("checksums.md5"))
    }

    @Test("A part that cannot be read is not 'intact': the sheet blocks Install")
    func unreadablePartBlocksSheet() async throws {
        let (center, folder) = try sheetFixture("sheet-unreadable")
        let part = folder.appending(path: "data-02.bin").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: part)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: part) }
        guard !FileManager.default.isReadableFile(atPath: part) else { return } // running as root
        center.open([folder])
        #expect(await waitFor { !center.sheet.isAnalyzing })
        let sums = try #require(center.sheet.items.first { $0.id == "sums" })
        #expect(sums.title.hasPrefix("data-02.bin could not be read to the end"))
        #expect(sums.check == .failed)
        #expect(!center.sheet.canContinue)
    }

    @Test("Verify-first fails the install on a part that cannot be read, before any Wine runs")
    func unreadablePartFailsVerifyFirst() async throws {
        let (center, folder) = try sheetFixture("verify-unreadable")
        let part = folder.appending(path: "data-02.bin").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: part)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: part) }
        guard !FileManager.default.isReadableFile(atPath: part) else { return }
        let manifest = try Checksums.parse(folder.appending(path: "MD5/checksums.md5"))
        let request = InstallRequest(setup: folder.appending(path: "setup.exe"), source: folder, name: "Sample Game",
                                     appID: nil, gogID: nil, expectedBytes: 1, installerBytes: 1,
                                     installerFiles: [], manifest: manifest)
        var inputs = InstallInputs(runnerID: "r", gameName: "Sample Game")
        inputs.verifyFirst = true
        let job = InstallJob(request: request, inputs: inputs)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.problem == "data-02.bin could not be read to the end. Download it again, then drop it here.")
        #expect(job.folder == nil)
    }
}

// The same rules end to end, with the fake Wine and driver.
@MainActor
@Suite("Installer fallback flow", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct InstallerFallbackFlowTests {

    @Test("A missing driver fails clearly; Try Again runs the original setup under Wine")
    func missingDriverThenSetup() async throws {
        let fake = try FakeUnpack("fallback-nodriver")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog(), driverMissing: true), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.directUnpackFailed)
        #expect(job.problem?.contains("original setup under Wine") == true)
        #expect(!fake.calledWith().contains { $0.contains("setup.exe") })

        center.sheet.tryAgain()
        #expect(job.request.directUnpack == nil)
        #expect(await waitFor(60) { fake.calledWith().contains { $0.contains("setup.exe") } })
        #expect(!fake.calledWith().contains { $0.contains("unarc-driver.exe") })
        #expect(FileManager.default.fileExists(atPath: fake.source.appending(path: "data-01.bin").path))
    }

    @Test("A part that fails to unpack offers the standard method: the retry fix runs setup, not the driver")
    func failedPartThenSetup() async throws {
        let fake = try FakeUnpack("fallback-part", behavior: "fail")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor { job.phase == .failed })
        #expect(job.diagnosis?.kind == .decompression)
        #expect(job.directUnpackFailed)
        let drivers = fake.calledWith().filter { $0.contains("unarc-driver.exe") }.count

        let fix = try #require(center.sheet.fixes.first)
        center.sheet.retry(fix)
        #expect(job.request.directUnpack == nil)
        #expect(await waitFor(60) { fake.calledWith().contains { $0.contains("setup.exe") } })
        #expect(fake.calledWith().filter { $0.contains("unarc-driver.exe") }.count == drivers)
    }

    @Test("Stop during innoextract ends it at once, and the attempt's folder is cleaned up")
    func stopDuringInnoextract() async throws {
        let fake = try FakeUnpack("fallback-stop-inno")
        let slow = fake.work.appending(path: "innoextract-slow")
        try executable(slow, "echo started >> '\(fake.work.appending(path: "slow.log").path)'\nsleep 60")
        var engine = fake.engine(winetricks: VerbLog())
        engine.innoextract = { slow.path(percentEncoded: false) }
        engine.toolRunner = { CancellableToolRunner(timeout: 120) }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) {
            FileManager.default.fileExists(atPath: fake.work.appending(path: "slow.log").path)
        })
        let folder = try #require(job.folder)
        let stopped = Date()
        center.stop(job)
        #expect(await waitFor(20) { job.phase == .stopped })
        #expect(Date().timeIntervalSince(stopped) < 15)
        #expect(!FileManager.default.fileExists(atPath: folder.root.path))
    }

    @Test("Queuing the same game while the first waits at the program step leaves its folder alone")
    func secondInstallKeepsFirstFolder() async throws {
        let fake = try FakeInstall("held-second")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let first = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.enqueue(first)
        #expect(await waitFor(60) { first.phase == .choosing || first.phase == .failed })
        #expect(first.phase == .choosing)
        let kept = try #require(first.folder)

        let second = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.enqueue(second)
        #expect(await waitFor(60) { second.phase == .choosing || second.phase == .failed })
        #expect(second.folder?.root != kept.root)
        #expect(FileManager.default.fileExists(atPath: kept.prefix.path))
        #expect(!first.candidates.isEmpty)
        #expect(first.candidates.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
