// Everything it starts is a Wine process or a macOS tool; nothing from the installer's folder runs outside Wine.

import Foundation
import InstallerKit

struct InstallEngine: Sendable {

    // A Wine process log keeps its head and drops its middle past this size
    static let outputLimit: Int64 = 32 << 20

    // Where new games go; the library moves it when the user picks another games location
    var installs: URL = GameFolder.installs
    var runners: URL = SupportPaths.runners
    var registry: @Sendable () -> RunnerRegistry = { RunnerRegistry.refresh(free: .standard) }
    var environment: [String: String] = SetupEnvironment.base
    var setupDefaults: @Sendable () -> SetupDefaults = { SetupDefaults.load() }
    var backendAvailability: @Sendable (RunnerRegistry, URL) -> BackendAvailability = {
        BackendAvailability.current(registry: $0, runners: $1)
    }
    var policy = InstallRun.Policy()
    var verbTimeout: TimeInterval = 300
    var keepAwake = true
    var steam = SteamShortcuts()
    var winetricks: @Sendable (_ verbs: [String], _ prefix: URL, _ wine: WineRunner, _ log: URL) async throws -> InstallRun
        = InstallerWinetricks.run
    var innoextract: @Sendable () -> String? = { Innoextract.path() }
    var toolRunner: @Sendable () -> any ToolRunning = { CancellableToolRunner(timeout: 900) }
    var unpackerDriver: @Sendable () -> URL? = { InstallPayload.unpackerDriver() }
    var freeSpace: @Sendable (URL) -> Int64? = { Disk.freeBytes(at: $0) }
    // Dropped archives unpack here; a game imported from it moves into its prefix.
    var dropStaging: URL = SupportPaths.dropStaging

    // The registry's signature checks run codesign, so the list never builds on the caller's actor.
    func runnerIDs() async -> [String] {
        let registry = registry
        return await Task.detached { InstallRunners.choices(registry()).map(\.id) }.value
    }

    @MainActor
    func run(_ job: InstallJob) async {
        job.stopRequested = false
        await runAttempt(job)
        await settle(job)
    }

    @MainActor
    private func runAttempt(_ job: InstallJob) async {
        let request = job.request
        let inputs = job.inputs
        job.problem = nil
        job.diagnosis = nil
        job.directUnpackFailed = false
        job.progress = InstallProgress(expected: request.expectedBytes)
        job.run = nil
        job.bootLog = nil

        if let plan = request.importing {
            await runImport(job, plan)
            return
        }

        if inputs.verifyFirst, let manifest = request.manifest {
            job.phase = .verifying
            do {
                let results = try await Checksums.verify(manifest, root: request.source)
                let damaged = Checksums.damaged(results)
                if let first = damaged.first {
                    job.fail(String(localized: "\(first) is damaged. Download it again."))
                    return
                }
                // A part that cannot be read to the end would stop the unpack halfway: as bad as damaged.
                if let first = Checksums.unreadable(results).first {
                    job.fail(String(localized: "\(first) could not be read to the end. Download it again, then drop it here."))
                    return
                }
            } catch {
                stopped(job)
                return
            }
        }
        guard !Task.isCancelled else { stopped(job); return }

        guard let made = await makePrefix(job) else { return }
        let (folder, wine) = made
        do {
            if inputs.shortSource { try WineInstall.mapSource(request.source, prefix: folder.prefix) }
            if inputs.externalUnpacker { try WineInstall.makeTemp(prefix: folder.prefix) }
        } catch {
            job.fail(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { stopped(job); return }

        // An installer with an external unpacker whose pattern the kit recognizes skips setup
        // entirely: the driver unpacks the parts straight into the install dir.
        if let plan = request.directUnpack {
            await runDirectUnpack(job, plan: plan, folder: folder, wine: wine)
            return
        }

        // An installer that uses an external unpacker gets the prefix it needs before setup runs:
        // Windows version 10 and the runtimes the unpacker links against.
        if let unpacker = request.unpacker, !unpacker.winetricksVerbs.isEmpty {
            let log = folder.root.appending(path: "winetricks-unpacker.log")
            do {
                let run = try await winetricks(unpacker.winetricksVerbs, folder.prefix, wine, log)
                job.run = run
                try run.start()
                let status = await run.exitStatus()
                if run.wasStopped || Task.isCancelled { stopped(job); return }
                job.unpackerPrepInstalled = status == 0
                if status != 0 {
                    AppLog.note("installer: unpacker preparation \(unpacker.winetricksVerbs) stopped with status \(status); its output is in \(log.path(percentEncoded: false))")
                }
            } catch {
                if Task.isCancelled { stopped(job); return }
                AppLog.note("installer: unpacker preparation failed: \(error.localizedDescription)")
                job.unpackerPrepInstalled = false
            }
            await waitForWine(wine, prefix: folder.prefix)
        }

        job.phase = .installing
        let launch = WineInstall.runSetup(request.setup, runner: wine, prefix: folder.prefix, inputs: job.inputs, base: environment)
        let journal = ProcessJournal(file: folder.root.appending(path: "processes.log"))
        let run = InstallRun(launch, output: folder.wineOutput, outputLimit: Self.outputLimit)
        job.run = run
        do { try run.start() } catch {
            job.fail(error.localizedDescription)
            return
        }
        if keepAwake { Self.keepAwake(while: run.pid) }

        let installDir = WinePath.unix(job.inputs.installDir, prefix: folder.prefix) ?? folder.prefix
        let cls = CLSPatches(prefix: folder.prefix, inputs: job.inputs)
        let status = await run.monitor(folder: installDir, expected: request.expectedBytes, policy: policy,
                                       journal: journal, onTick: { cls.apply() }) { progress in
            Task { @MainActor in if job.phase == .installing { job.progress = progress } }
        }
        journal?.finish(root: run.pid, status: status)
        journal?.close()
        await waitForWine(wine, prefix: folder.prefix)
        if run.wasStopped || Task.isCancelled {
            stopped(job)
            return
        }

        let logFile = WinePath.unix(job.inputs.log, prefix: folder.prefix)
        let log = logFile.flatMap(InstallLog.read)
        if let logFile { try? FileManager.default.copyItem(at: logFile, to: folder.root.appending(path: "install.log")) }
        let diagnosis = InstallLog.diagnose(exitCode: status, log: log, wineLog: InstallLog.read(folder.wineOutput))
        guard diagnosis.succeeded else {
            job.diagnosis = diagnosis
            if case .cancelled = diagnosis.kind {
                stopped(job)
                return
            }
            job.phase = .failed
            return
        }

        guard await verifyOutput(job, in: installDir) else { return }
        await finishScan(job, in: installDir, folder: folder, wine: wine)
    }

    // Direct unpacking for installers with external unpackers: the helpers come out of the
    // installer's tmp section, the bundled driver then unpacks each part in the order the parts
    // list gives them, and the shipped manifest verifies what landed. setup never runs.
    @MainActor
    private func runDirectUnpack(_ job: InstallJob, plan: DirectUnpackPlan, folder: GameFolder, wine: WineRunner) async {
        let request = job.request

        // The parts decompress where they land and scratch next to them; a shortfall is fatal mid-run.
        let needed = request.expectedBytes + max(Int64(2) << 30, request.expectedBytes / 10)
        if let free = freeSpace(folder.prefix), free < needed {
            job.fail(String(localized: "Not enough free space to unpack the game (about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .binary)) needed)."))
            return
        }
        guard let tool = innoextract() else {
            directUnpackFailed(job, String(localized: "innoextract is missing, so the installer's helper files could not be read."))
            return
        }
        guard let driver = unpackerDriver() else {
            directUnpackFailed(job, String(localized: "\(DirectUnpack.driverName) is missing from the app's resources."))
            return
        }

        job.phase = .installing
        do {
            try WineInstall.mapSource(request.source, prefix: folder.prefix)
            try WineInstall.makeTemp(prefix: folder.prefix)
            try await prepareUnpack(setup: request.setup, inputs: job.inputs, plan: plan,
                                    folder: folder, driver: driver, tool: tool)
        } catch {
            if Task.isCancelled { stopped(job); return }
            directUnpackFailed(job, error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { stopped(job); return }

        let installDir = WinePath.unix(job.inputs.installDir, prefix: folder.prefix) ?? folder.prefix
        let journal = ProcessJournal(file: folder.root.appending(path: "processes.log"))
        for (index, part) in plan.parts.enumerated() {
            let launch = WineInstall.runUnpackDriver(
                part: part, plan: plan, installDir: job.inputs.installDir,
                runner: wine, prefix: folder.prefix, inputs: job.inputs, base: environment
            )
            let log = folder.root.appending(path: "unpack-\(index + 1)-\(part.lastPathComponent).log")
            let run = InstallRun(launch, output: log, outputLimit: Self.outputLimit)
            job.run = run
            do { try run.start() } catch {
                journal?.close()
                directUnpackFailed(job, error.localizedDescription)
                return
            }
            if keepAwake { Self.keepAwake(while: run.pid) }
            journal?.note("part \(index + 1) of \(plan.parts.count): \(part.lastPathComponent)")
            let status = await run.monitor(folder: installDir, expected: request.expectedBytes, policy: policy, journal: journal) { progress in
                Task { @MainActor in if job.phase == .installing { job.progress = progress } }
            }
            journal?.finish(root: run.pid, status: status)
            if run.wasStopped || Task.isCancelled {
                journal?.close()
                await killPrefix(wine, prefix: folder.prefix)
                stopped(job)
                return
            }
            guard status == 0 else {
                journal?.close()
                directUnpackFailed(job, diagnosis: DirectUnpack.diagnose(status: status, log: InstallLog.read(log)))
                return
            }
        }
        journal?.close()
        await waitForWine(wine, prefix: folder.prefix)
        guard !Task.isCancelled else { stopped(job); return }

        // The app section carries the manifest and any redistributables; it lands over the
        // unpacked tree the way the installer would have placed it.
        let sections = folder.root.appending(path: "installer-sections")
        let appTree = sections.appending(path: DirectUnpack.appSection)
        if FileManager.default.fileExists(atPath: appTree.path(percentEncoded: false)) {
            do { try Self.mergeContents(of: appTree, into: installDir) } catch {
                directUnpackFailed(job, String(localized: "The unpacked files could not be moved into place. \(error.localizedDescription)"))
                return
            }
        }

        guard await verifyOutput(job, in: installDir) else { return }
        await finishScan(job, in: installDir, folder: folder, wine: wine)
    }

    // Pulls the helpers and app section out of the setup with the bundled innoextract, stages the
    // helpers in the prefix's short path, and lands the driver next to them.
    private func prepareUnpack(setup: URL, inputs: InstallInputs, plan: DirectUnpackPlan,
                               folder: GameFolder, driver: URL, tool: String) async throws {
        let sections = folder.root.appending(path: "installer-sections")
        let runner = toolRunner()
        // Stop terminates innoextract at once; the attempt's cleanup then runs as for any stop.
        try await withTaskCancellationHandler {
            try await Task.detached {
                try Innoextract.extract(setup: setup, section: DirectUnpack.helperSection, into: sections, tool: tool, runner: runner)
                try Innoextract.extract(setup: setup, section: DirectUnpack.appSection, into: sections, tool: tool, runner: runner)
            }.value
        } onCancel: {
            (runner as? CancellableToolRunner)?.cancel()
        }
        try Task.checkCancellation()
        let helpers = folder.prefix.appending(path: DirectUnpack.helperUnixDir)
        try Self.mergeContents(of: sections.appending(path: DirectUnpack.helperSection), into: helpers)
        // ADR 0025: a native tool may stand in for a shipped helper only on an exact allowlisted
        // hash. The allowlist is empty today, so the shipped Windows helpers always run.
        let staged = (try? FileManager.default.contentsOfDirectory(at: helpers, includingPropertiesForKeys: nil)) ?? []
        let natives = staged.compactMap(HelperAllowlist.nativeReplacement)
        if !natives.isEmpty {
            AppLog.note("installer: allowlisted native helpers \(natives.joined(separator: ", "))")
        }
        try FileManager.default.copyItem(at: driver, to: helpers.appending(path: DirectUnpack.driverName))
        if let ini = plan.clsConfig {
            _ = try DirectUnpack.patchConfig(
                at: helpers.appending(path: ini), tempDir: WineInstall.shortTemp,
                memoryPercent: inputs.memoryPercent, threads: inputs.threads
            )
        }
    }

    // Copies the tree over the destination: folders on both sides merge, only same-named files are replaced.
    static func mergeContents(of source: URL, into dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: source.path(percentEncoded: false)) {
            let from = source.appending(path: item), to = dest.appending(path: item)
            if isFolder(from), isFolder(to) {
                try mergeContents(of: from, into: to)
                continue
            }
            if (try? fm.attributesOfItem(atPath: to.path(percentEncoded: false))) != nil { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    // Direct unpacking could not run or did not finish: the job fails with the reason, and any
    // retry runs the original setup under Wine with its own helpers (InstallCenter.useStandardMethod).
    @MainActor
    private func directUnpackFailed(_ job: InstallJob, _ problem: String? = nil, diagnosis: InstallDiagnosis? = nil) {
        let note = String(localized: "Unpacking directly did not work. A retry runs the original setup under Wine, with its own helpers.")
        AppLog.note("installer: direct unpack of \(job.title) failed: \(problem ?? diagnosis?.detail ?? "no detail"); a retry runs setup")
        job.directUnpackFailed = true
        job.diagnosis = diagnosis
        job.fail(problem.map { $0 + " " + note } ?? note)
    }

    private func killPrefix(_ wine: WineRunner, prefix: URL) async {
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: environment)
        await WineServer.kill(server: wine.server, env: env)
    }

    // The ADR 0025/0026 gate before a game may be marked installed: the shipped manifest or the
    // archive CRC the unpack just proved (full), else the script's file list and sizes (partial),
    // else the install stays "Installed, not verified". A mismatch fails the job; the recovery
    // choices reach it through the presenter via InstallCenter.onVerificationMismatch.
    @MainActor
    private func verifyOutput(_ job: InstallJob, in installDir: URL) async -> Bool {
        job.verificationDir = installDir
        var manifest: ChecksumManifest?
        var manifestRel: String?
        if let rel = job.request.directUnpack?.manifestPath {
            let url = installDir.appending(path: rel)
            if let found = GameVerify.usableManifest(at: url, root: installDir) {
                manifest = found
                manifestRel = rel
            }
        }
        if manifest == nil, job.request.directUnpack == nil,
           let url = Checksums.findManifest(in: installDir),
           let found = GameVerify.usableManifest(at: url, root: installDir) {
            manifest = found
            manifestRel = GameVerify.relative(url, under: installDir)
        }
        let files = await scriptFiles(for: job)
        guard !Task.isCancelled else { stopped(job); return false }

        if let manifest {
            job.phase = .verifying
            do {
                let bad = try await GameVerify.checkManifest(manifest, root: installDir) { done, total, _ in
                    Task { @MainActor in
                        guard job.phase == .verifying else { return }
                        job.progress.fraction = min(0.99, Double(done) / Double(max(1, total)))
                    }
                }
                job.verification = VerificationOutcome(
                    status: bad.isEmpty ? .full : .notVerified, level: .manifest,
                    mismatched: bad, manifest: manifestRel, files: files.isEmpty ? nil : files)
            } catch {
                stopped(job)
                return false
            }
        } else if job.request.directUnpack != nil {
            // The driver's clean unarc exit is the parts' FreeArc CRC check already passed.
            job.verification = VerificationOutcome(status: .full, level: .crc,
                                                   files: files.isEmpty ? nil : files)
            return true
        } else if !files.isEmpty {
            job.phase = .verifying
            do {
                let bad = try await GameVerify.checkSizes(files, root: installDir) { done, total, _ in
                    Task { @MainActor in
                        guard job.phase == .verifying else { return }
                        job.progress.fraction = min(0.99, Double(done) / Double(max(1, total)))
                    }
                }
                job.verification = VerificationOutcome(
                    status: bad.isEmpty ? .sizes : .notVerified, level: .sizes,
                    mismatched: bad, files: files)
            } catch {
                stopped(job)
                return false
            }
        } else {
            job.verification = VerificationOutcome(status: .notVerified, level: .unavailable)
            return true
        }

        guard let outcome = job.verification, !outcome.mismatched.isEmpty else { return true }
        job.diagnosis = InstallDiagnosis(
            kind: .damagedFile, causes: [.damagedFile], fixes: [.verifyFiles], exitCode: 0,
            detail: outcome.mismatched.prefix(3).joined(separator: ", "))
        job.phase = .failed
        return false
    }

    // The script's file list and sizes, the partial evidence: app/ entries are what lands in the
    // install dir. Persisted so Verify Files… can check again after the installer folder is gone.
    @MainActor
    private func scriptFiles(for job: InstallJob) async -> [VerificationFile] {
        guard job.request.importing == nil else { return [] }
        let setup = job.request.setup, tool = innoextract(), runner = toolRunner()
        let entries = try? await withTaskCancellationHandler {
            try await Task.detached { () throws -> [InnoFileEntry] in
                try GameVerify.scriptEntries(setup, tool: tool, runner: runner)
            }.value
        } onCancel: {
            (runner as? CancellableToolRunner)?.cancel()
        }
        return GameVerify.installedFiles(from: entries ?? [])
    }

    // Keep Anyway: the install continues to the launcher step; its record keeps the
    // not-verified outcome and the mismatched files land in the folder's log.
    @MainActor
    func resumeAfterMismatch(_ job: InstallJob) async {
        job.stopRequested = false
        await resumeAttempt(job)
        await settle(job)
    }

    @MainActor
    private func resumeAttempt(_ job: InstallJob) async {
        guard job.phase == .failed, let outcome = job.verification, !outcome.mismatched.isEmpty,
              let folder = job.folder, let installDir = job.verificationDir else { return }
        let load = registry
        let registry = await Task.detached { load() }.value
        guard let runner = registry.runner(id: job.inputs.runnerID) ?? InstallRunners.choices(registry).first,
              let wine = InstallRunners.wine(for: runner, runners: runners) else {
            job.fail(String(localized: "No runner is set up for installs. Set one up in Runners first."))
            return
        }
        job.diagnosis = nil
        job.problem = nil
        let log = folder.root.appending(path: "verification-mismatch.log")
        try? Data((outcome.mismatched.joined(separator: "\n") + "\n").utf8).write(to: log)
        AppLog.note("verification: \(job.title) kept \(outcome.mismatched.count) mismatched files, listed in \(log.path(percentEncoded: false))")
        for file in outcome.mismatched { AppLog.note("verification: mismatch \(file)") }
        job.phase = .redistributables
        if let plan = job.request.importing {
            let exe = plan.copy || StagedGames.isStaged(plan.folder, staging: dropStaging)
                ? GameCopy.rebase(plan.exe, from: plan.folder, to: installDir) : plan.exe
            guard await installRedistributables(job, exe: exe, folder: folder, wine: wine) else { return }
            job.progress.fraction = 1
            do {
                job.steamOutcome = try await finish(job, exe: exe, showInSteam: plan.showInSteam)
            } catch {
                job.fail(error.localizedDescription)
            }
        } else {
            await finishScan(job, in: installDir, folder: folder, wine: wine)
        }
    }

    // The shared tail of an install: launcher candidates from the unpacked files, the runtimes
    // they need, and on to the launcher's choice step.
    @MainActor
    private func finishScan(_ job: InstallJob, in installDir: URL, folder: GameFolder, wine: WineRunner) async {
        let prefix = folder.prefix
        // Both walk the unpacked tree, thousands of stats: never on the main actor.
        let scan = await Task.detached {
            let gog = GOGInfo.find(in: installDir)
            let primary = gog.flatMap { found in found.info.primaryExe.map { found.url.deletingLastPathComponent().appending(path: $0) } }
            return ExeDetector.scan(installFolder: installDir, prefix: prefix, primary: primary)
        }.value
        guard !Task.isCancelled else { stopped(job); return }
        job.installFolder = scan.installFolder
        job.candidates = scan.candidates

        guard await installRedistributables(job, in: scan.installFolder, folder: folder, wine: wine) else { return }
        job.progress.fraction = 1
        job.phase = .choosing
    }

    // An installed game: a fresh prefix, the files copied or left where they are, its runtimes, then the record.
    @MainActor
    private func runImport(_ job: InstallJob, _ plan: GameImport) async {
        guard let made = await makePrefix(job) else { return }
        let (folder, wine) = made
        guard !Task.isCancelled else { stopped(job); return }
        var game = plan.folder, exe = plan.exe
        // An extracted archive is never used from Caches: in place or copied, it moves into the prefix.
        let staged = StagedGames.isStaged(plan.folder, staging: dropStaging)
        if plan.copy || staged {
            job.phase = .installing
            let target = StagedGames.home(for: job.request.name, prefix: folder.prefix)
            let report: @Sendable (Int64) -> Void = { bytes in
                Task { @MainActor in
                    guard job.phase == .installing else { return }
                    job.progress.bytes = bytes
                    job.progress.fraction = min(1, Double(bytes) / Double(max(1, job.request.expectedBytes)))
                }
            }
            do {
                job.progress.bytes = try await staged
                    ? GameMove.relocate(plan.folder, to: target, freeSpace: freeSpace, progress: report)
                    : GameCopy.copy(plan.folder, to: target, progress: report)
            } catch {
                if Task.isCancelled { stopped(job); return }
                job.fail(String(localized: "Copying \(job.request.name) failed. \(error.localizedDescription)"))
                return
            }
            guard !Task.isCancelled else { stopped(job); return }
            exe = GameCopy.rebase(plan.exe, from: plan.folder, to: target)
            game = target
        }
        job.installFolder = game
        guard await verifyOutput(job, in: game) else { return }
        guard await installRedistributables(job, exe: exe, folder: folder, wine: wine) else { return }
        job.progress.fraction = 1
        do {
            job.steamOutcome = try await finish(job, exe: exe, showInSteam: plan.showInSteam)
        } catch {
            job.fail(error.localizedDescription)
            return
        }
        if staged {
            let source = plan.folder, staging = dropStaging
            await Task.detached { StagedGames.discard(source, staging: staging) }.value
        }
    }

    @MainActor
    private func makePrefix(_ job: InstallJob) async -> (GameFolder, WineRunner)? {
        job.phase = .preparing
        // Refreshing the registry checks codesignatures: the probes wait on processes, so they run detached.
        let load = registry
        let registry = await Task.detached { load() }.value
        guard let runner = registry.runner(id: job.inputs.runnerID) ?? InstallRunners.choices(registry).first,
              let wine = InstallRunners.wine(for: runner, runners: runners) else {
            job.fail(String(localized: "No runner is set up for installs. Set one up in Runners first."))
            return nil
        }
        job.inputs.runnerID = runner.id
        do {
            let folder = try GameFolder.fresh(for: job.request.name, in: installs, held: job.heldFolders)
            job.folder = folder
            // Preparing Windows environment: wineboot -u, then wineserver -w, shared if asked twice.
            let boot = WineBootstrap.begin(wine: wine, prefix: folder.prefix, base: environment,
                                           log: folder.root.appending(path: "prefix.log"))
            job.bootStarted = boot.prepares ? boot.started : nil
            job.run = boot.run
            // prefix.log is created by the boot task's own run; look for it off the main actor.
            if let log = boot.log, boot.prepares {
                Task.detached { [weak job] in
                    for _ in 0..<50 where !Task.isCancelled {
                        if FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
                            await MainActor.run { job?.bootLog = log }
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            switch await boot.outcome.value {
            case .ready:
                return (folder, wine)
            case .stopped:
                stopped(job)
                return nil
            case .failed(let detail):
                job.fail(detail)
                return nil
            }
        } catch {
            job.fail(error.localizedDescription)
            return nil
        }
    }

    // An installed game's needs come from its own programs' imports, never from its redist folders.
    @MainActor
    private func installRedistributables(_ job: InstallJob, exe: URL, folder: GameFolder, wine: WineRunner) async -> Bool {
        let steps = await Task.detached { RuntimeScan.scan(exe: exe).steps }.value
        return await installRedistributables(job, steps: steps, folder: folder, wine: wine)
    }

    // The bundled runtime installers found after a setup ran; .NET is left out because Wine Mono covers it.
    @MainActor
    private func installRedistributables(_ job: InstallJob, in game: URL, folder: GameFolder, wine: WineRunner) async -> Bool {
        let steps = await Task.detached {
            var seen: Set<String> = []
            return Redistributables.find(in: game).filter { $0.family != .dotNet }
                .compactMap { seen.insert($0.verb).inserted ? RuntimeStep(verb: $0.verb, label: $0.label) : nil }
        }.value
        return await installRedistributables(job, steps: steps, folder: folder, wine: wine)
    }

    // One verb at a time so a stuck one is named, timed out and skipped instead of hanging the import.
    @MainActor
    private func installRedistributables(_ job: InstallJob, steps: [RuntimeStep], folder: GameFolder, wine: WineRunner) async -> Bool {
        job.runtimeSteps = steps
        guard !steps.isEmpty else { return true }
        guard !Task.isCancelled else { stopped(job); return false }
        job.phase = .redistributables
        let log = folder.root.appending(path: PrefixTools.winetricksLogName)
        for i in job.runtimeSteps.indices {
            job.runtimeSteps[i].status = .installing
            job.skipRuntime = false
            let verb = job.runtimeSteps[i].verb
            do {
                let run = try await winetricks([verb], folder.prefix, wine, log)
                job.run = run
                try run.start()
                let timedOut = await exceeded(run, timeout: verbTimeout)
                if Task.isCancelled { stopped(job); return false }
                let status = await run.exitStatus()
                if timedOut || (job.skipRuntime && status != 0) {
                    job.runtimeSteps[i].status = .skipped
                    if timedOut {
                        AppLog.note("installer: winetricks \(verb) did not finish in \(Int(verbTimeout)) s and was skipped; its output is in \(log.path(percentEncoded: false))")
                    }
                } else {
                    job.runtimeSteps[i].status = status == 0 ? .installed : .failed
                    if status != 0 {
                        AppLog.note("installer: winetricks \(verb) stopped with status \(status); its output is in \(log.path(percentEncoded: false))")
                    }
                }
            } catch {
                if Task.isCancelled { stopped(job); return false }
                AppLog.note("installer: winetricks \(verb) failed: \(error.localizedDescription)")
                job.runtimeSteps[i].status = .failed
            }
        }
        await waitForWine(wine, prefix: folder.prefix)
        return true
    }

    // True when the run was killed for taking longer than the verb timeout; the verb's own
    // process group is killed, prefix-scoped, rather than the whole Wine session.
    private func exceeded(_ run: InstallRun, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await run.exitStatus(); return false }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return !Task.isCancelled
            }
            let hit = await group.next() ?? false
            group.cancelAll()
            if hit {
                run.stop()
                _ = await run.exitStatus()
            }
            return hit
        }
    }

    @MainActor
    func finish(_ job: InstallJob, exe: URL, showInSteam: Bool, steam: SteamShortcuts? = nil) async throws -> SteamShortcuts.Outcome? {
        guard let folder = job.folder else { return nil }
        let request = job.request, inputs = job.inputs, steps = job.runtimeSteps
        let verification = job.verificationRecord
        let engine = self
        // The registry scan, the launcher, the record and the Steam shortcut's process probe: none of it belongs on the main actor.
        let made = try await Task.detached {
            try engine.writeInstall(folder: folder, request: request, inputs: inputs, runtimeSteps: steps,
                                    exe: exe, showInSteam: showInSteam, steam: steam,
                                    verification: verification)
        }.value
        job.game = made.game
        job.phase = .ready
        return made.steam
    }

    // Everything finish writes or probes, run off the caller's actor.
    private func writeInstall(folder: GameFolder, request: InstallRequest, inputs: InstallInputs,
                              runtimeSteps: [RuntimeStep], exe: URL, showInSteam: Bool,
                              steam: SteamShortcuts?, verification: VerificationRecord?) throws -> (game: InstalledGame, steam: SteamShortcuts.Outcome?) {
        let registry = registry()
        guard let runner = registry.runner(id: inputs.runnerID),
              let wine = InstallRunners.wine(for: runner, runners: runners) else {
            throw StepFailure(step: String(localized: "Write the game's launcher"),
                              detail: String(localized: "The runner that installed the game is not set up anymore."))
        }
        // The graphics default is the one any Windows game gets: the user's default pick, else the runner's first backend.
        let offered = BackendSupport.backends(for: runner, translation: .rosetta,
                                              availability: backendAvailability(registry, runners))
        let backend = setupDefaults().graphics.flatMap { offered.contains($0) ? $0 : nil } ?? offered.first ?? .wined3d
        SetupEnvironment.prepare(backend, prefix: folder.prefix)
        try GameLauncher.write(exe: exe, folder: folder, wine: wine, backend: backend, runners: runners)
        var game = InstalledGame(
            id: folder.root.lastPathComponent, name: request.name, appID: request.appID, gogID: request.gogID,
            runnerID: inputs.runnerID, graphics: backend.rawValue,
            wineVersion: runner.version, wineRunnerKind: runner.kind.rawValue,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: exe.path(percentEncoded: false), installedAt: Date(),
            installerFolder: request.source.path(percentEncoded: false),
            redistributables: runtimeSteps.filter { $0.status == .installed }.map(\.verb),
            gameFolder: request.importing.flatMap {
                $0.copy || StagedGames.isStaged($0.folder, staging: dropStaging) ? nil : $0.folder.path(percentEncoded: false)
            },
            verification: verification
        )
        var outcome: SteamShortcuts.Outcome?
        if showInSteam {
            outcome = (steam ?? self.steam).add(name: game.name, launcher: folder.launcher, startDir: exe.deletingLastPathComponent())
            game.steamShortcut = outcome == .added || outcome == .alreadyThere
        }
        try InstalledGames.save(game, in: folder)
        return (game, outcome)
    }

    @MainActor
    func stop(_ job: InstallJob) {
        if let folder = job.folder { WineBootstrap.stop(folder.prefix) }
        job.run?.stop()
        job.task?.cancel()
    }

    @MainActor
    private func stopped(_ job: InstallJob) {
        job.stopRequested = true
    }

    // A stopped or cancelled attempt ends once its Wine session is gone and its folder removed, so a retry starts clean.
    @MainActor
    private func settle(_ job: InstallJob) async {
        guard job.phase != .ready, Task.isCancelled || job.stopRequested else { return }
        await discard(job)
    }

    // Every path that ends an attempt stopped waits on the same cleanup, so it runs once.
    @MainActor
    func discard(_ job: InstallJob) async {
        if let running = job.cleanup {
            await running.value
            return
        }
        let cleanup = Task { await removeAttempt(job) }
        job.cleanup = cleanup
        await cleanup.value
        job.cleanup = nil
    }

    // wineserver -k on this prefix first, so nothing writes into the folder once it is gone.
    // Only a folder Cartouche marked as an unfinished attempt is removed.
    @MainActor
    private func removeAttempt(_ job: InstallJob) async {
        guard let folder = job.folder else {
            job.phase = .stopped
            return
        }
        let load = registry, runners = runners, environment = environment, runnerID = job.inputs.runnerID
        do {
            try await Task.detached {
                guard !folder.isFinished else { return }
                if let runner = load().runner(id: runnerID),
                   let wine = InstallRunners.wine(for: runner, runners: runners) {
                    let env = WineInstall.environment(runner: wine, prefix: folder.prefix, inputs: nil, base: environment)
                    await WineServer.kill(server: wine.server, env: env)
                }
                if folder.isUnfinishedAttempt { try FileManager.default.removeItem(at: folder.root) }
            }.value
            job.folder = nil
            job.run = nil
            job.phase = .stopped
        } catch {
            job.fail(error.localizedDescription)
        }
    }

    private func waitForWine(_ wine: WineRunner, prefix: URL) async {
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: environment)
        await WineServer.wait(server: wine.server, env: env, timeout: 30)
    }

    // caffeinate -i -w keeps the Mac awake until the installer exits.
    private static func keepAwake(while pid: pid_t) {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-w", String(pid)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

final class CLSPatches: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Set<String> = []
    let prefix: URL
    let inputs: InstallInputs

    init(prefix: URL, inputs: InstallInputs) { self.prefix = prefix; self.inputs = inputs }

    func apply() {
        guard inputs.memoryPercent != nil || inputs.threads != nil else { return }
        lock.withLock { _ = CLSConfig.apply(in: prefix, inputs: inputs, done: &done) }
    }
}

enum InstallerWinetricks {

    @Sendable
    static func run(_ verbs: [String], prefix: URL, wine: WineRunner, log: URL) async throws -> InstallRun {
        let script = try await PinnedDownload.obtain(
            file: "winetricks", sha256: PrefixTools.winetricksSHA256,
            bases: [QAEnvironment.url(URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(PrefixTools.winetricksRelease)/src")!)],
            into: SupportPaths.winetricksDownloads, step: String(localized: "Run Winetricks"), from: "GitHub"
        )
        return try run(verbs, prefix: prefix, wine: wine, log: log, script: script)
    }

    static func run(_ verbs: [String], prefix: URL, wine: WineRunner, log: URL, script: URL) throws -> InstallRun {
        let wrapper = script.deletingLastPathComponent().appending(path: "cartouche-wine")
        try Data(PrefixTools.winetricksWine.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path(percentEncoded: false))
        var env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: SetupEnvironment.base)
        env["WINE"] = wrapper.path(percentEncoded: false)
        env["CARTOUCHE_WINE"] = wine.loader.path(percentEncoded: false)
        env["WINE_BIN"] = wine.loader.path(percentEncoded: false)
        return InstallRun(InstallLaunch(executable: "/bin/sh", arguments: [script.path(percentEncoded: false), "-q"] + verbs,
                                        environment: env), output: log)
    }
}
