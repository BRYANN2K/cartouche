import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// A game's files as the install leaves them, plus a scratch installs/<slug> folder with the
// record Verify Files… reads. The game id is installer:<slug> so GameVerificationCenter finds it.
private struct ScratchInstall {
    let installs: URL
    let folder: GameFolder
    let gameDir: URL
    let game: Game
    var record: InstalledGame { InstalledGames.record(in: folder)! }
}

@MainActor
private func scratchInstall(
    _ label: String,
    files: [String: String] = ["game.exe": "game-bytes", "data/data.bin": "payload"],
    record: (inout InstalledGame) -> Void = { _ in }
) throws -> ScratchInstall {
    let installs = try scratchDirectory("vc-\(label)")
    let folder = GameFolder(root: installs.appending(path: "sample-game"))
    let gameDir = installs.appending(path: "game-dir/Sample Game")
    for (name, content) in files {
        let url = gameDir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    var made = InstalledGame(
        id: "sample-game", name: "Sample Game", appID: nil, gogID: nil, runnerID: "runner",
        prefix: folder.prefix.path(percentEncoded: false),
        exe: gameDir.appending(path: "game.exe").path(percentEncoded: false), installedAt: Date(),
        installerFolder: installs.appending(path: "missing-installer").path(percentEncoded: false),
        redistributables: [], gameFolder: gameDir.path(percentEncoded: false))
    record(&made)
    try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
    try InstalledGames.save(made, in: folder)
    return ScratchInstall(installs: installs, folder: folder, gameDir: gameDir,
                          game: Game(id: "installer:sample-game", source: .installer, name: "Sample Game", installed: true))
}

private func writeManifest(_ dir: URL, name: String = "files.md5", entries: [(md5: String, path: String)]) throws -> URL {
    let url = dir.appending(path: name)
    let text = entries.map { "\($0.md5) *\($0.path)" }.joined(separator: "\n") + "\n"
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}

private func md5(_ url: URL) throws -> String { try Checksums.md5(of: url) }

private func record(_ s: ScratchInstall) -> InstalledGame { InstalledGames.record(in: s.folder)! }

@Suite("Output verification checks")
struct OutputVerificationTests {

    @Test("Full level: every shipped hash passing leaves no mismatched names")
    func manifestPass() async throws {
        let dir = try scratchDirectory("ov-full")
        let files = ["game.exe": "game-bytes", "data.bin": "payload"]
        for (name, content) in files { try Data(content.utf8).write(to: dir.appending(path: name)) }
        let manifestURL = try writeManifest(dir, entries: [
            (try md5(dir.appending(path: "game.exe")), "game.exe"),
            (try md5(dir.appending(path: "data.bin")), "data.bin"),
        ])
        let manifest = try #require(GameVerify.usableManifest(at: manifestURL, root: dir))
        let progress = ProgressLog()
        let bad = try await GameVerify.checkManifest(manifest, root: dir) { done, total, file in
            progress.add(done, total, file)
        }
        #expect(bad.isEmpty)
        #expect(progress.calls.last?.done == 2 && progress.calls.last?.total == 2)
    }

    @Test("Changed and absent files are named, sorted, never silently verified")
    func manifestMismatch() async throws {
        let dir = try scratchDirectory("ov-bad")
        try Data("game-bytes".utf8).write(to: dir.appending(path: "game.exe"))
        let manifestURL = try writeManifest(dir, entries: [
            ("00000000000000000000000000000000", "zzz-absent.exe"),
            ("11111111111111111111111111111111", "game.exe"),
        ])
        // The absent file does not make the manifest unusable while game.exe exists inside the root.
        let manifest = try #require(GameVerify.usableManifest(at: manifestURL, root: dir))
        let bad = try await GameVerify.checkManifest(manifest, root: dir)
        #expect(bad == ["game.exe", "zzz-absent.exe"])
    }

    @Test("A manifest naming only absent files is not output evidence")
    func manifestUnusable() throws {
        let dir = try scratchDirectory("ov-unusable")
        try Data("game-bytes".utf8).write(to: dir.appending(path: "game.exe"))
        let manifestURL = try writeManifest(dir, entries: [
            (try md5(dir.appending(path: "game.exe")), "..\\data-01.bin"),
            (try md5(dir.appending(path: "game.exe")), "..\\data-02.bin"),
        ])
        #expect(GameVerify.usableManifest(at: manifestURL, root: dir) == nil)
    }

    @Test("Partial level: presence and sizes pass; wrong size and missing are named")
    func sizes() async throws {
        let dir = try scratchDirectory("ov-sizes")
        try Data("12345".utf8).write(to: dir.appending(path: "game.exe"))
        try Data("x".utf8).write(to: dir.appending(path: "data.bin"))
        let bad = try await GameVerify.checkSizes([
            VerificationFile(path: "game.exe", bytes: 5),
            VerificationFile(path: "data.bin", bytes: 1),
            VerificationFile(path: "wrong.bin", bytes: 9),
            VerificationFile(path: "missing.dll", bytes: 0),
        ], root: dir)
        #expect(bad == ["missing.dll", "wrong.bin"])
        let ok = try await GameVerify.checkSizes([VerificationFile(path: "game.exe", bytes: 5)], root: dir)
        #expect(ok.isEmpty)
    }

    @Test("The script's file list keeps only the app section, rebased under the install dir")
    func installedFiles() {
        let files = GameVerify.installedFiles(from: [
            InnoFileEntry(path: #"app\game.exe"#, bytes: 10),
            InnoFileEntry(path: #"app\data\data.bin"#, bytes: 20),
            InnoFileEntry(path: #"tmp\unarc.dll"#, bytes: 30),
            InnoFileEntry(path: "app\\", bytes: 0),
            InnoFileEntry(path: #"APP\UPPER.EXE"#, bytes: 5),
        ])
        #expect(files == [
            VerificationFile(path: "game.exe", bytes: 10),
            VerificationFile(path: "data/data.bin", bytes: 20),
            VerificationFile(path: "UPPER.EXE", bytes: 5),
        ])
    }

    @Test("A supplied checksum list reads ..\\ and plain paths against the game dir")
    func supplied() async throws {
        let dir = try scratchDirectory("ov-supplied")
        try Data("game-bytes".utf8).write(to: dir.appending(path: "game.exe"))
        let list = try scratchDirectory("ov-supplied-list").appending(path: "dropped.md5")
        try Data("\(try md5(dir.appending(path: "game.exe"))) *..\\game.exe\n; comment\n".utf8).write(to: list)
        let manifest = try GameVerify.suppliedManifest(list, gameDir: dir)
        #expect(manifest.entries.count == 1)
        #expect(manifest.entries[0].file.standardizedFileURL == dir.appending(path: "game.exe").standardizedFileURL)
        let bad = try await GameVerify.checkManifest(manifest, root: dir)
        #expect(bad.isEmpty)
    }

    @Test("Stop mid-check throws; nothing partial counts as verified")
    func stop() async throws {
        let dir = try scratchDirectory("ov-stop")
        var entries: [(md5: String, path: String)] = []
        for i in 0..<40 {
            let name = "f\(i).bin"
            try Data("x".utf8).write(to: dir.appending(path: name))
            entries.append((try md5(dir.appending(path: name)), name))
        }
        let manifest = try #require(GameVerify.usableManifest(at: try writeManifest(dir, entries: entries), root: dir))
        let task = Task {
            try await GameVerify.checkManifest(manifest, root: dir, perFile: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(done: Int, total: Int, file: String)] = []
    func add(_ done: Int, _ total: Int, _ file: String) { lock.withLock { all.append((done, total, file)) } }
    var calls: [(done: Int, total: Int, file: String)] { lock.withLock { all } }
}

@MainActor
@Suite("Game verification center", .serialized)
struct GameVerificationCenterTests {

    private func center(in installs: URL) -> GameVerificationCenter {
        let center = GameVerificationCenter()
        center.installs = installs
        return center
    }

    // An install center that cannot run real installs: retries land in jobs and fail on the
    // missing runner, which is all these assertions need.
    private func installCenter(in installs: URL, mismatch: GameVerificationCenter? = nil) -> InstallCenter {
        let runners = installs.appending(path: "empty-runners")
        let center = InstallCenter(
            engine: InstallEngine(installs: installs, runners: runners, registry: { RunnerRegistry(runners: []) }),
            notifier: RecordingNotifier())
        if let mismatch { center.onVerificationMismatch = { mismatch.presentMismatch(for: $0) } }
        return center
    }

    @Test("The status comes from the record, not from installed state")
    func statusReadsRecord() throws {
        let s = try scratchInstall("status", record: { $0.verification = VerificationRecord(status: .full) })
        let center = center(in: s.installs)
        #expect(center.status(for: s.game.id) == .full)
        #expect(center.status(for: "installer:unknown") == .notVerified)
    }

    @Test("Verify Files… runs the shipped manifest and persists full")
    func verifyShippedManifest() async throws {
        let s = try scratchInstall("verify-full")
        try Data("game-bytes".utf8).write(to: s.gameDir.appending(path: "game.exe"))
        _ = try writeManifest(s.gameDir, entries: [
            (try md5(s.gameDir.appending(path: "game.exe")), "game.exe"),
            (try md5(s.gameDir.appending(path: "data/data.bin")), "data/data.bin"),
        ])
        let center = center(in: s.installs)
        center.verify(s.game)
        #expect(await waitFor { record(s).verification?.status == .full })
        #expect(record(s).verification?.level == .manifest)
        #expect(center.status(for: s.game.id) == .full)
    }

    @Test("A manifest mismatch persists not verified, names the files and offers the three choices")
    func verifyMismatch() async throws {
        let s = try scratchInstall("verify-mismatch")
        _ = try writeManifest(s.gameDir, entries: [("00000000000000000000000000000000", "game.exe")])
        let center = center(in: s.installs)
        center.verify(s.game)
        #expect(await waitFor { center.mismatch != nil })
        #expect(center.mismatch?.gameID == s.game.id)
        #expect(center.mismatch?.files == ["game.exe"])
        #expect(record(s).verification?.status == .notVerified)
        #expect(record(s).verification?.mismatched == ["game.exe"])

        // Cancel: nothing retries, nothing gets marked verified.
        center.cancelMismatch(gameID: s.game.id)
        #expect(center.mismatch == nil)
        #expect(record(s).verification?.status == .notVerified)
    }

    @Test("Keep Anyway leaves the game not verified")
    func verifyKeepAnyway() async throws {
        let s = try scratchInstall("verify-keep")
        _ = try writeManifest(s.gameDir, entries: [("00000000000000000000000000000000", "game.exe")])
        let center = center(in: s.installs)
        center.verify(s.game)
        #expect(await waitFor { center.mismatch != nil })
        center.keepAnyway(gameID: s.game.id)
        #expect(center.mismatch == nil)
        #expect(record(s).verification?.status == .notVerified)
        #expect(center.status(for: s.game.id) == .notVerified)
    }

    @Test("The recorded file list verifies sizes later, without the installer")
    func verifySizesLater() async throws {
        let s = try scratchInstall("verify-sizes", files: ["game.exe": "12345", "data/data.bin": "payload"]) { record in
            var verification = VerificationRecord(status: .notVerified)
            verification.files = [
                VerificationFile(path: "game.exe", bytes: 5),
                VerificationFile(path: "data/data.bin", bytes: 7),
            ]
            record.verification = verification
        }
        let center = center(in: s.installs)
        center.verify(s.game)
        #expect(await waitFor { record(s).verification?.status == .sizes })
        #expect(record(s).verification?.level == .sizes)
        #expect(center.status(for: s.game.id) == .sizes)
    }

    @Test("A checksum list the user drops verifies a not-verified game")
    func verifySupplied() async throws {
        let s = try scratchInstall("verify-supplied")
        let list = s.installs.appending(path: "dropped.md5")
        try Data("\(try md5(s.gameDir.appending(path: "game.exe"))) *..\\game.exe\n".utf8).write(to: list)
        let center = center(in: s.installs)
        center.verify(s.game, checksums: list)
        #expect(await waitFor { record(s).verification?.status == .full })
        #expect(record(s).verification?.level == .supplied)
    }

    @Test("Stop mid-check leaves the game not verified and clears the progress")
    func verifyStop() async throws {
        var files: [String: String] = [:]
        for i in 0..<40 { files["f\(i).bin"] = "x" }
        let s = try scratchInstall("verify-stop", files: files) {
            $0.verification = VerificationRecord(status: .full)
        }
        var entries: [(md5: String, path: String)] = []
        for i in 0..<40 {
            entries.append((try md5(s.gameDir.appending(path: "f\(i).bin")), "f\(i).bin"))
        }
        _ = try writeManifest(s.gameDir, entries: entries)
        let center = center(in: s.installs)
        center.fileDelay = .milliseconds(20)
        center.verify(s.game)
        #expect(await waitFor { center.progress(for: s.game.id) != nil })
        center.stop(gameID: s.game.id)
        #expect(await waitFor { record(s).verification?.status == .notVerified })
        #expect(center.progress(for: s.game.id) == nil)
        #expect(center.status(for: s.game.id) == .notVerified)
    }

    @Test("A job's mismatch routes Retry through the center; the fallback order is helpers, then guided setup")
    func jobMismatchRetryOrder() async throws {
        let s = try scratchInstall("retry-order")
        let vc = center(in: s.installs)
        let installs = installCenter(in: s.installs, mismatch: vc)
        vc.center = installs

        var request = InstallRequest(setup: s.installs.appending(path: "setup.exe"), source: s.installs,
                                   name: "Sample Game", appID: nil, gogID: nil, expectedBytes: 0,
                                   installerBytes: 0, installerFiles: [], manifest: nil)
        request.directUnpack = DirectUnpackPlan(parts: [], helpers: ["unarc.dll"], unarcModule: "unarc.dll",
                                                arcConfig: "arc.ini", clsConfig: nil, manifestPath: "files.md5")
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: "runner", gameName: "Sample Game", mode: .automatic))
        job.phase = .failed
        job.verification = VerificationOutcome(status: .notVerified, level: .manifest, mismatched: ["game.exe"])
        // A live mismatch belongs to a job the center still holds: pump only runs jobs it knows.
        installs.enqueue(job)

        vc.presentMismatch(for: job)
        #expect(vc.mismatch?.gameID == GameVerificationCenter.jobID(job))
        vc.retryStandard(gameID: GameVerificationCenter.jobID(job))
        #expect(vc.mismatch == nil)
        // First fallback: the installer's own helpers, original settings — the unpack plan stays.
        #expect(job.verificationFallback == 1)
        #expect(job.inputs.externalUnpacker)
        #expect(job.inputs.mode == .guided)
        #expect(job.request.directUnpack != nil)

        // The runnerless engine fails fast; the mismatch comes back through the presenter.
        #expect(await waitFor { job.phase == .failed })
        #expect(await waitFor { vc.mismatch != nil })
        vc.retryStandard(gameID: GameVerificationCenter.jobID(job))
        // Last resort: setup itself, guided; no unpack plan, no helper profile.
        #expect(job.verificationFallback == 2)
        #expect(job.request.directUnpack == nil)
        #expect(!job.inputs.externalUnpacker)
        #expect(await waitFor { job.phase == .failed })
    }

    @Test("Retry on a finished in-place import enqueues the same check again")
    func recordRetryReImports() async throws {
        let s = try scratchInstall("retry-import")
        let vc = center(in: s.installs)
        let installs = installCenter(in: s.installs)
        vc.center = installs

        _ = try writeManifest(s.gameDir, entries: [("00000000000000000000000000000000", "game.exe")])
        vc.verify(s.game)
        #expect(await waitFor { vc.mismatch != nil })
        vc.retryStandard(gameID: s.game.id)
        #expect(vc.mismatch == nil)
        #expect(await waitFor { !installs.jobs.isEmpty })
        let retry = try #require(installs.jobs.last)
        #expect(retry.verificationFallback == 1)
        #expect(retry.request.importing?.copy == false)
        #expect(retry.inputs.mode == .guided)
    }

    @Test("Retrying a finished install whose installer folder is gone does nothing")
    func recordRetryMissingSource() async throws {
        // The record names an installerFolder that does not exist: nothing to rebuild the request from.
        let s = try scratchInstall("retry-gone") { $0.gameFolder = nil }
        let vc = center(in: s.installs)
        let installs = installCenter(in: s.installs)
        vc.center = installs
        _ = try writeManifest(s.gameDir, entries: [("00000000000000000000000000000000", "game.exe")])
        vc.verify(s.game)
        #expect(await waitFor { vc.mismatch != nil })
        vc.retryStandard(gameID: s.game.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(installs.jobs.isEmpty)
    }
}

@MainActor
@Suite("Install verification gate", .serialized, .enabled(if: rosettaAvailable, "Rosetta is not installed, so arch -x86_64 cannot run"))
struct VerificationGateTests {

    @Test("Direct unpack: the shipped manifest verifies the output and the record keeps it")
    func unpackManifestVerified() async throws {
        let fake = try FakeUnpack("gate-manifest")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .choosing })
        #expect(job.verification?.status == .full)
        #expect(job.verification?.level == .manifest)

        let exe = try #require(job.candidates.first?.path)
        _ = try await center.engine.finish(job, exe: URL(filePath: exe), showInSteam: false)
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(record.verification?.status == .full)
        #expect(record.verification?.level == .manifest)
        #expect(record.verification?.manifest == "_Redist/game.md5")
        #expect(record.verification?.gameDir != nil)
    }

    @Test("Direct unpack without a manifest trusts the CRC the unpack already proved")
    func unpackCRC() async throws {
        let fake = try FakeUnpack("gate-crc")
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var request = fake.request()
        request.directUnpack?.manifestPath = nil
        let job = InstallJob(request: request, inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .choosing })
        #expect(job.verification?.status == .full)
        #expect(job.verification?.level == .crc)
    }

    @Test("A mismatch fails the job; Keep Anyway resumes it, stays not verified, and logs the files")
    func unpackMismatchKeepAnyway() async throws {
        let fake = try FakeUnpack("gate-keep", badManifest: true)
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var presented: [InstallJob] = []
        center.onVerificationMismatch = { presented.append($0) }
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .failed })
        #expect(presented.count == 1 && presented.first === job)
        #expect(job.verification?.status == .notVerified)
        #expect(job.verification?.mismatched == ["game.exe"])
        #expect(job.diagnosis?.kind == .damagedFile)

        center.keepAnyway(job)
        #expect(await waitFor(60) { job.phase == .choosing })
        let folder = try #require(job.folder)
        let logged = try String(contentsOf: folder.root.appending(path: "verification-mismatch.log"), encoding: .utf8)
        #expect(logged.contains("game.exe"))

        let exe = try #require(job.candidates.first?.path)
        _ = try await center.engine.finish(job, exe: URL(filePath: exe), showInSteam: false)
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(record.verification?.status == .notVerified)
        #expect(record.verification?.mismatched == ["game.exe"])
    }

    @Test("Retry with the standard method reruns the shipped helpers, then falls back to guided setup")
    func unpackMismatchRetryOrder() async throws {
        let fake = try FakeUnpack("gate-retry", badManifest: true)
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var presented = 0
        center.onVerificationMismatch = { _ in presented += 1 }
        let job = InstallJob(request: fake.request(), inputs: fake.inputs())
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .failed })
        let drivers = fake.calledWith().filter { $0.contains("unarc-driver.exe") }.count

        // First fallback: the installer's own helpers, original settings — the driver runs again.
        center.retryStandard(job)
        #expect(job.verificationFallback == 1)
        #expect(job.inputs.externalUnpacker)
        #expect(job.request.directUnpack != nil)
        #expect(await waitFor(60) { job.phase == .failed && fake.calledWith().filter { $0.contains("unarc-driver.exe") }.count > drivers })
        #expect(presented == 2)
        #expect(!FileManager.default.fileExists(atPath: fake.trap.path))

        // Last resort: the real installer, guided — setup.exe runs and the unpack plan is gone.
        center.retryStandard(job)
        #expect(job.verificationFallback == 2)
        #expect(job.request.directUnpack == nil)
        #expect(await waitFor(60) { job.phase == .failed || job.phase == .choosing })
        #expect(fake.calledWith().contains { $0.contains("setup.exe") })
    }

    @Test("A setup install checks the script's file list and sizes; the mismatch is a damaged-file failure")
    func setupSizes() async throws {
        let fake = try FakeInstall("gate-sizes")
        var engine = fake.engine(winetricks: VerbLog())
        // innoextract --list-sizes for this installer: the app section's promised sizes.
        let tool = fake.work.appending(path: "innoextract-sizes")
        try Data("""
        #!/bin/sh
        printf '1200000 app\\\\game.exe\\n2000 app\\\\unins000.exe\\n1000 app\\\\_Redist\\\\dxwebsetup.exe\\n1000 app\\\\_Redist\\\\dotNetFx40_Full_setup.exe\\n'
        """.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        engine.innoextract = { tool.path(percentEncoded: false) }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .choosing })
        #expect(job.verification?.status == .sizes)
        #expect(job.verification?.level == .sizes)
        #expect(job.verification?.files?.isEmpty == false)

        let exe = try #require(job.candidates.first?.path)
        _ = try await center.engine.finish(job, exe: URL(filePath: exe), showInSteam: false)
        let record = try #require(InstalledGames.all(in: fake.installs).first)
        #expect(record.verification?.status == .sizes)
        #expect(record.verification?.files?.contains(VerificationFile(path: "game.exe", bytes: 1_200_000)) == true)
    }

    @Test("A size the script does not keep fails the install")
    func setupSizesMismatch() async throws {
        let fake = try FakeInstall("gate-sizes-bad")
        var engine = fake.engine(winetricks: VerbLog())
        let tool = fake.work.appending(path: "innoextract-sizes")
        try Data("#!/bin/sh\nprintf '1 app\\\\game.exe\\n'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        engine.innoextract = { tool.path(percentEncoded: false) }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        var presented = 0
        center.onVerificationMismatch = { _ in presented += 1 }
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .failed })
        #expect(job.verification?.status == .notVerified)
        #expect(job.verification?.mismatched == ["game.exe"])
        #expect(job.diagnosis?.kind == .damagedFile)
        #expect(presented == 1)
    }

    @Test("Neither checksum nor script list: the install finishes 'not verified'")
    func setupUnavailable() async throws {
        let fake = try FakeInstall("gate-none")
        var engine = fake.engine(winetricks: VerbLog())
        engine.innoextract = { nil }
        let center = InstallCenter(engine: engine, notifier: RecordingNotifier())
        let job = InstallJob(request: fake.request(), inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.sheet.show(job)
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .choosing })
        #expect(job.verification?.status == .notVerified)
        #expect(job.verification?.level == .unavailable)

        let exe = try #require(job.candidates.first?.path)
        _ = try await center.engine.finish(job, exe: URL(filePath: exe), showInSteam: false)
        #expect(InstalledGames.all(in: fake.installs).first?.verification?.status == .notVerified)
    }

    @Test("An import verifies the folder where it is; a manifest mismatch fails and retries in place")
    func importVerification() async throws {
        let fake = try FakeInstall("gate-import")
        let game = fake.work.appending(path: "Volumes/SSD/Sample Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("game-bytes".utf8).write(to: game.appending(path: "game.exe"))
        _ = try writeManifest(game, entries: [(try md5(game.appending(path: "game.exe")), "game.exe")])
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var request = InstallRequest(setup: game, source: game, name: "Sample Game", appID: nil, gogID: nil,
                                     expectedBytes: 0, installerBytes: 0, installerFiles: [], manifest: nil)
        request.importing = GameImport(folder: game, exe: game.appending(path: "game.exe"), copy: false, showInSteam: false)
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .ready || job.phase == .failed })
        #expect(job.phase == .ready)
        #expect(job.verification?.status == .full)
        #expect(InstalledGames.all(in: fake.installs).first?.verification?.status == .full)
    }

    @Test("An import mismatch fails; the standard-method retry imports the folder again")
    func importMismatchRetry() async throws {
        let fake = try FakeInstall("gate-import-bad")
        let game = fake.work.appending(path: "Volumes/SSD/Sample Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("game-bytes".utf8).write(to: game.appending(path: "game.exe"))
        _ = try writeManifest(game, entries: [("00000000000000000000000000000000", "game.exe")])
        let center = InstallCenter(engine: fake.engine(winetricks: VerbLog()), notifier: RecordingNotifier())
        var presented = 0
        center.onVerificationMismatch = { _ in presented += 1 }
        var request = InstallRequest(setup: game, source: game, name: "Sample Game", appID: nil, gogID: nil,
                                     expectedBytes: 0, installerBytes: 0, installerFiles: [], manifest: nil)
        request.importing = GameImport(folder: game, exe: game.appending(path: "game.exe"), copy: false, showInSteam: false)
        let job = InstallJob(request: request, inputs: InstallInputs(runnerID: fake.runner.id, gameName: "Sample Game"))
        center.enqueue(job)
        #expect(await waitFor(60) { job.phase == .failed })
        #expect(presented == 1)

        center.retryStandard(job)
        #expect(job.verificationFallback == 1)
        #expect(job.inputs.mode == .guided)
        #expect(await waitFor(60) { job.phase == .failed })
        #expect(presented == 2)
    }
}
