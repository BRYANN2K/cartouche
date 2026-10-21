// The live backend for the verification UI. It reads the persisted state off each game's
// install record, re-checks files off the main actor, and routes the mismatch choices —
// Retry with the Standard Method through the installer's own helpers and original settings,
// Keep Anyway, Cancel (ADR 0026).

import Foundation
import InstallerKit
import Observation

@MainActor
@Observable
final class GameVerificationCenter: GameVerificationPresenting {

    @ObservationIgnored var installs: URL = GameFolder.installs
    // Nil falls back to .shared, so tests never construct the app-wide center.
    @ObservationIgnored var center: InstallCenter?
    // innoextract, for the script's file list when the record doesn't carry it.
    @ObservationIgnored var tool: @Sendable () -> String? = { Innoextract.path() }
    @ObservationIgnored var toolRunner: @Sendable () -> any ToolRunning = { ProcessToolRunner(timeout: 120) }
    // Test hook: slows the file loop so Stop can land mid-check.
    @ObservationIgnored var fileDelay: Duration = .zero

    private(set) var mismatch: GameVerificationMismatch?
    private var running: [String: Task<Void, Never>] = [:]
    private var progresses: [String: GameVerificationProgress] = [:]
    private var supplied: [String: URL] = [:]
    // Which install the pending mismatch belongs to: a job still in the center, or a finished record.
    private var targets: [String: Target] = [:]

    private enum Target {
        case job(InstallJob)
        case record(GameFolder)
    }

    private enum Evidence {
        case manifest(ChecksumManifest, level: VerificationLevel, relative: String?)
        case files([VerificationFile])

        var total: Int {
            switch self {
            case .manifest(let manifest, _, _): manifest.entries.count
            case .files(let files): files.count
            }
        }

        // A check weaker than the recorded one would only downgrade it.
        var rank: Int {
            switch self {
            case .manifest: 2
            case .files: 1
            }
        }
    }

    static let jobPrefix = "job:"

    // The id the mismatch sheet uses for a job still installing — no game record exists for it yet.
    static func jobID(_ job: InstallJob) -> String { jobPrefix + job.id.uuidString }

    func status(for gameID: String) -> GameVerificationStatus {
        guard let folder = folderFor(gameID),
              let record = InstalledGames.record(in: folder) else { return .notVerified }
        return record.verification?.status ?? .notVerified
    }

    func progress(for gameID: String) -> GameVerificationProgress? { progresses[gameID] }

    func verify(_ game: Game) { begin(game) }

    // A checksum list dropped onto the game: its paths read against the game dir.
    func verify(_ game: Game, checksums manifest: URL) {
        supplied[game.id] = manifest
        begin(game)
    }

    func stop(gameID: String) {
        running[gameID]?.cancel()
        progresses[gameID] = nil
        persistStopped(for: gameID)
    }

    // The install gate found mismatches; the sheet gets the job's list and the job stays failed
    // until a choice moves it.
    func presentMismatch(for job: InstallJob) {
        let id = Self.jobID(job)
        targets[id] = .job(job)
        mismatch = GameVerificationMismatch(gameID: id, files: job.verification?.mismatched ?? [])
    }

    func retryStandard(gameID: String) {
        let target = targets[gameID]
        mismatch = nil
        targets[gameID] = nil
        switch target {
        case .job(let job):
            (center ?? .shared).retryStandard(job)
        case .record(let folder):
            Task { await retryInstalled(in: folder) }
        case nil:
            break
        }
    }

    func keepAnyway(gameID: String) {
        let files = mismatch?.files ?? []
        let target = targets[gameID]
        mismatch = nil
        targets[gameID] = nil
        switch target {
        case .job(let job):
            // The engine resumes the install and writes the record's not-verified outcome.
            (center ?? .shared).keepAnyway(job)
        case .record(let folder):
            // The record already carries not verified and the mismatched names; this logs them.
            AppLog.note("verification: kept \(files.count) mismatched files in \(folder.root.path(percentEncoded: false))")
            for file in files { AppLog.note("verification: mismatch \(file)") }
        case nil:
            break
        }
    }

    // Cancel: nothing retries, nothing gets marked verified, the output stays where it is.
    func cancelMismatch(gameID: String) {
        mismatch = nil
        targets[gameID] = nil
    }

    private func folderFor(_ gameID: String) -> GameFolder? {
        guard gameID.hasPrefix("installer:") else { return nil }
        return GameFolder(root: installs.appending(path: String(gameID.dropFirst("installer:".count))))
    }

    private func begin(_ game: Game) {
        guard game.source == .installer, game.installed, let folder = folderFor(game.id),
              InstalledGames.record(in: folder) != nil else { return }
        running[game.id]?.cancel()
        running[game.id] = Task { await self.check(game: game, folder: folder) }
    }

    private func check(game: Game, folder: GameFolder) async {
        defer { running[game.id] = nil; progresses[game.id] = nil }
        guard var record = InstalledGames.record(in: folder) else { return }
        let gameDir = self.gameDir(for: record)
        let suppliedList = supplied.removeValue(forKey: game.id)
        do {
            guard let evidence = try await evidence(for: record, gameDir: gameDir, supplied: suppliedList)
            else { return }
            // A check weaker than the recorded one would only downgrade it.
            let recorded = record.verification?.status.rank ?? 0
            guard evidence.rank >= recorded else { return }
            progresses[game.id] = GameVerificationProgress(completed: 0, total: evidence.total, file: "")
            let outcome = try await run(evidence, in: gameDir, gameID: game.id)
            record = InstalledGames.record(in: folder) ?? record
            record.verification = outcome.record(gameDir: gameDir)
            try? InstalledGames.save(record, in: folder)
            guard outcome.mismatched.isEmpty else {
                targets[game.id] = .record(folder)
                mismatch = GameVerificationMismatch(gameID: game.id, files: outcome.mismatched)
                return
            }
        } catch {
            // Stop lands here too: the record keeps not verified.
            persistStopped(for: game.id)
        }
    }

    // Evidence in strength order: the list the user dropped, the manifest the install recorded,
    // a manifest shipped into the game dir, the script's file list it recorded, the same list
    // derived from the installer when the record predates verification.
    private func evidence(
        for record: InstalledGame, gameDir: URL, supplied manifest: URL?
    ) async throws -> Evidence? {
        if let manifest {
            let parsed = try GameVerify.suppliedManifest(manifest, gameDir: gameDir)
            return parsed.entries.isEmpty ? nil : .manifest(parsed, level: .supplied, relative: nil)
        }
        if let rel = record.verification?.manifest,
           let found = GameVerify.usableManifest(at: gameDir.appending(path: rel), root: gameDir) {
            return .manifest(found, level: .manifest, relative: rel)
        }
        if let url = Checksums.findManifest(in: gameDir),
           let found = GameVerify.usableManifest(at: url, root: gameDir) {
            return .manifest(found, level: .manifest, relative: GameVerify.relative(url, under: gameDir))
        }
        if let files = record.verification?.files, !files.isEmpty { return .files(files) }
        let derived = try await scriptFiles(for: record)
        return derived.isEmpty ? nil : .files(derived)
    }

    private func run(_ evidence: Evidence, in gameDir: URL, gameID: String) async throws -> VerificationOutcome {
        let note: @Sendable (Int, Int, String) -> Void = { [weak self] done, total, file in
            Task { @MainActor [weak self] in
                self?.progresses[gameID] = GameVerificationProgress(completed: done, total: total, file: file)
            }
        }
        switch evidence {
        case .manifest(let manifest, let level, let rel):
            let bad = try await GameVerify.checkManifest(manifest, root: gameDir, perFile: fileDelay, progress: note)
            return VerificationOutcome(status: bad.isEmpty ? .full : .notVerified,
                                       level: level, mismatched: bad, manifest: rel)
        case .files(let files):
            let bad = try await GameVerify.checkSizes(files, root: gameDir, perFile: fileDelay, progress: note)
            return VerificationOutcome(status: bad.isEmpty ? .sizes : .notVerified,
                                       level: .sizes, mismatched: bad, files: files)
        }
    }

    // Where the install's files live: the dir the check ran against, the folder the import used,
    // or the exe's parent for records that predate the verification field.
    private func gameDir(for record: InstalledGame) -> URL {
        if let dir = record.verification?.gameDir { return URL(filePath: dir) }
        if let folder = record.gameFolder { return URL(filePath: folder) }
        return record.exeURL.deletingLastPathComponent()
    }

    private func scriptFiles(for record: InstalledGame) async throws -> [VerificationFile] {
        let source = URL(filePath: record.installerFolder)
        guard let scan = try? PartScanner.scan(source), let setup = scan.setup else { return [] }
        let tool = tool(), runner = toolRunner()
        let entries = try? await Task.detached { () throws -> [InnoFileEntry] in
            try InnoInspector.listSizes(setup, tool: tool, runner: runner)
        }.value
        return GameVerify.installedFiles(from: entries ?? [])
    }

    // Stop never verifies: the status goes back to not verified, the evidence pointers stay so a
    // later Verify Files… can run again.
    private func persistStopped(for gameID: String) {
        guard let folder = folderFor(gameID),
              var record = InstalledGames.record(in: folder) else { return }
        if var current = record.verification {
            current.status = .notVerified
            current.checkedAt = Date()
            current.mismatched = []
            record.verification = current
        } else {
            record.verification = VerificationRecord(status: .notVerified)
        }
        try? InstalledGames.save(record, in: folder)
    }

    // The standard method for a finished install: rebuild the request from the record — the
    // installer's own helpers and original settings when the parts allow it, the guided real
    // installer under Wine as the last resort, or the import copy again.
    private func retryInstalled(in folder: GameFolder) async {
        guard let record = InstalledGames.record(in: folder) else { return }
        guard let job = await retryJob(for: record) else {
            AppLog.note("verification: cannot retry \(record.name); its installer folder is gone")
            return
        }
        // The retry installs in place: the finished record steps aside so fresh() reuses the slug.
        try? FileManager.default.removeItem(at: folder.record)
        FileManager.default.createFile(atPath: folder.attempt.path(percentEncoded: false), contents: Data())
        (center ?? .shared).enqueue(job)
    }

    private func retryJob(for record: InstalledGame) async -> InstallJob? {
        if let gameFolder = record.gameFolder {
            // An import in place has no installer: the retry runs the check again in place.
            var request = InstallRequest(
                setup: URL(filePath: gameFolder), source: URL(filePath: gameFolder),
                name: record.name, appID: record.appID, gogID: record.gogID,
                expectedBytes: 0, installerBytes: 0, installerFiles: [], manifest: nil)
            request.importing = GameImport(folder: URL(filePath: gameFolder), exe: record.exeURL,
                                           copy: false, showInSteam: record.steamShortcut)
            let job = InstallJob(request: request,
                                 inputs: InstallInputs(runnerID: record.runnerID, gameName: record.name))
            job.verificationFallback = 1
            return job
        }
        let source = URL(filePath: record.installerFolder)
        let tool = tool(), runner = toolRunner()
        guard let found = try? await Task.detached(operation: { () throws -> (PartScan, InnoReport?) in
            let scan = try PartScanner.scan(source)
            let inno = try scan.setup.map { try InnoInspector.inspect($0, tool: tool, runner: runner) }
            return (scan, inno)
        }).value, let setup = found.0.setup else {
            // No setup left: what the folder still is, is a copied game's source — import it again.
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)),
                  let scan = try? PartScanner.scan(source), scan.setup == nil, scan.parts.isEmpty
            else { return nil }
            var request = InstallRequest(
                setup: source, source: source, name: record.name, appID: record.appID,
                gogID: record.gogID, expectedBytes: 0, installerBytes: 0,
                installerFiles: [], manifest: nil)
            request.importing = GameImport(folder: source, exe: record.exeURL,
                                           copy: true, showInSteam: record.steamShortcut)
            let job = InstallJob(request: request,
                                 inputs: InstallInputs(runnerID: record.runnerID, gameName: record.name))
            job.verificationFallback = 1
            return job
        }
        let (scan, inno) = found
        var request = InstallRequest(
            setup: setup, source: source, name: record.name, appID: record.appID, gogID: record.gogID,
            expectedBytes: SpaceEstimate.from(compressed: scan.totalSize,
                                              heavy: inno?.heavyDecompression ?? false).installed,
            installerBytes: scan.totalSize, installerFiles: [setup] + scan.parts.map { $0.url }, manifest: nil)
        request.unpacker = ExternalUnpacker.detect(inno: inno, folder: source)
        request.directUnpack = DirectUnpack.plan(inno: inno, scan: scan)
        var inputs = InstallInputs(runnerID: record.runnerID, gameName: record.name, mode: .guided)
        let job: InstallJob
        if request.directUnpack != nil {
            // First try: the installer's own shipped helpers, original settings.
            inputs.externalUnpacker = true
            job = InstallJob(request: request, inputs: inputs)
            job.verificationFallback = 1
        } else {
            // No direct-unpack pattern: the last resort is the guided real installer.
            request.directUnpack = nil
            inputs.externalUnpacker = request.unpacker != nil
            job = InstallJob(request: request, inputs: inputs)
            job.verificationFallback = 2
        }
        return job
    }
}

private extension VerificationOutcome {
    func record(gameDir: URL) -> VerificationRecord {
        VerificationRecord(outcome: self, gameDir: gameDir)
    }
}

private extension GameVerificationStatus {
    var rank: Int {
        switch self {
        case .notVerified: 0
        case .sizes: 1
        case .full: 2
        }
    }
}
