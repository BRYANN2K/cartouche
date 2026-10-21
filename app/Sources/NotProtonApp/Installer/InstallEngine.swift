// Everything it starts is a Wine process or a macOS tool; nothing from the installer's folder runs outside Wine.

import Foundation
import InstallerKit

struct InstallEngine: Sendable {

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
    var toolRunner: @Sendable () -> any ToolRunning = { ProcessToolRunner(timeout: 900) }
    var unpackerDriver: @Sendable () -> URL? = { InstallPayload.unpackerDriver() }
    var freeSpace: @Sendable (URL) -> Int64? = { Disk.freeBytes(at: $0) }

    func runnerIDs() -> [String] { InstallRunners.choices(registry()).map(\.id) }

    @MainActor
    func run(_ job: InstallJob) async {
        let request = job.request
        let inputs = job.inputs
        job.problem = nil
        job.diagnosis = nil
        job.progress = InstallProgress(expected: request.expectedBytes)
        job.run = nil

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
        let run = InstallRun(launch, output: folder.wineOutput, outputLimit: 32 << 20)
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
            job.fail(String(localized: "innoextract is missing, so the installer's helper files could not be read."))
            return
        }
        guard let driver = unpackerDriver() else {
            job.fail(String(localized: "\(DirectUnpack.driverName) is missing from the app's resources."))
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
            job.fail(error.localizedDescription)
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
            let run = InstallRun(launch, output: log, outputLimit: 32 << 20)
            job.run = run
            do { try run.start() } catch {
                journal?.close()
                job.fail(error.localizedDescription)
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
                job.diagnosis = DirectUnpack.diagnose(status: status, log: InstallLog.read(log))
                job.phase = .failed
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
            do { try Self.copyContents(of: appTree, into: installDir) } catch {
                job.fail(String(localized: "The unpacked files could not be moved into place. \(error.localizedDescription)"))
                return
            }
        }

        if let rel = plan.manifestPath,
           let manifest = try? Checksums.parse(installDir.appending(path: rel)), !manifest.entries.isEmpty {
            job.phase = .verifying
            let counted = ByteCount()
            do {
                let results = try await Checksums.verify(manifest, root: installDir) { hashed in
                    counted.add(hashed)
                    let total = counted.value
                    Task { @MainActor in
                        guard job.phase == .verifying else { return }
                        job.progress.bytes = total
                        job.progress.fraction = min(0.99, Double(total) / Double(max(1, job.progress.expected)))
                    }
                }
                let bad = results.filter { $0.value != ChecksumResult.ok }.map(\.key.lastPathComponent).sorted()
                guard bad.isEmpty else {
                    job.diagnosis = InstallDiagnosis(
                        kind: .damagedFile, causes: [.damagedFile], fixes: [.verifyFiles], exitCode: 0,
                        detail: bad.prefix(3).joined(separator: ", ")
                    )
                    job.phase = .failed
                    return
                }
            } catch {
                stopped(job)
                return
            }
        }

        await finishScan(job, in: installDir, folder: folder, wine: wine)
    }

    // Pulls the helpers and app section out of the setup with the bundled innoextract, stages the
    // helpers in the prefix's short path, and lands the driver next to them.
    private func prepareUnpack(setup: URL, inputs: InstallInputs, plan: DirectUnpackPlan,
                               folder: GameFolder, driver: URL, tool: String) async throws {
        let sections = folder.root.appending(path: "installer-sections")
        let runner = toolRunner()
        try await Task.detached {
            try Innoextract.extract(setup: setup, section: DirectUnpack.helperSection, into: sections, tool: tool, runner: runner)
            try Innoextract.extract(setup: setup, section: DirectUnpack.appSection, into: sections, tool: tool, runner: runner)
        }.value
        let helpers = folder.prefix.appending(path: DirectUnpack.helperUnixDir)
        try Self.copyContents(of: sections.appending(path: DirectUnpack.helperSection), into: helpers)
        try FileManager.default.copyItem(at: driver, to: helpers.appending(path: DirectUnpack.driverName))
        if let ini = plan.clsConfig {
            _ = try DirectUnpack.patchConfig(
                at: helpers.appending(path: ini), tempDir: WineInstall.shortTemp,
                memoryPercent: inputs.memoryPercent, threads: inputs.threads
            )
        }
    }

    // Moves every top-level entry into the destination, replacing same-named items.
    private static func copyContents(of source: URL, into dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: source.path(percentEncoded: false)) {
            let to = dest.appending(path: item)
            if fm.fileExists(atPath: to.path(percentEncoded: false)) { try fm.removeItem(at: to) }
            try fm.copyItem(at: source.appending(path: item), to: to)
        }
    }

    private func killPrefix(_ wine: WineRunner, prefix: URL) async {
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: environment)
        await WineServer.kill(server: wine.server, env: env)
    }

    // The shared tail of an install: launcher candidates from the unpacked files, the runtimes
    // they need, and on to the launcher's choice step.
    @MainActor
    private func finishScan(_ job: InstallJob, in installDir: URL, folder: GameFolder, wine: WineRunner) async {
        let gog = GOGInfo.find(in: installDir)
        let primary = gog.flatMap { found in found.info.primaryExe.map { found.url.deletingLastPathComponent().appending(path: $0) } }
        let scan = ExeDetector.scan(installFolder: installDir, prefix: folder.prefix, primary: primary)
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
        if plan.copy {
            job.phase = .installing
            let target = WinePath.unix(InstallInputs(runnerID: "", gameName: job.request.name).installDir, prefix: folder.prefix)
                ?? folder.prefix.appending(path: "drive_c/Games/Game")
            do {
                job.progress.bytes = try await GameCopy.copy(plan.folder, to: target) { bytes in
                    Task { @MainActor in
                        guard job.phase == .installing else { return }
                        job.progress.bytes = bytes
                        job.progress.fraction = min(1, Double(bytes) / Double(max(1, job.request.expectedBytes)))
                    }
                }
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
        guard await installRedistributables(job, exe: exe, folder: folder, wine: wine) else { return }
        job.progress.fraction = 1
        do {
            job.steamOutcome = try await finish(job, exe: exe, showInSteam: plan.showInSteam)
        } catch {
            job.fail(error.localizedDescription)
        }
    }

    @MainActor
    private func makePrefix(_ job: InstallJob) async -> (GameFolder, WineRunner)? {
        job.phase = .preparing
        let registry = registry()
        guard let runner = registry.runner(id: job.inputs.runnerID) ?? InstallRunners.choices(registry).first,
              let wine = InstallRunners.wine(for: runner, runners: runners) else {
            job.fail(String(localized: "No runner is set up for installs. Set one up in Runners first."))
            return nil
        }
        job.inputs.runnerID = runner.id
        do {
            let folder = try GameFolder.fresh(for: job.request.name, in: installs)
            job.folder = folder
            // Preparing Windows environment: wineboot -u, then wineserver -w, shared if asked twice.
            let boot = WineBootstrap.begin(wine: wine, prefix: folder.prefix, base: environment,
                                           log: folder.root.appending(path: "prefix.log"))
            job.bootStarted = boot.prepares ? boot.started : nil
            job.run = boot.run
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
        await installRedistributables(job, steps: RuntimeScan.scan(exe: exe).steps, folder: folder, wine: wine)
    }

    // The bundled runtime installers found after a setup ran; .NET is left out because Wine Mono covers it.
    @MainActor
    private func installRedistributables(_ job: InstallJob, in game: URL, folder: GameFolder, wine: WineRunner) async -> Bool {
        var seen: Set<String> = []
        let steps = Redistributables.find(in: game).filter { $0.family != .dotNet }
            .compactMap { seen.insert($0.verb).inserted ? RuntimeStep(verb: $0.verb, label: $0.label) : nil }
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
        let engine = self
        // The registry scan, the launcher, the record and the Steam shortcut's process probe: none of it belongs on the main actor.
        let made = try await Task.detached {
            try engine.writeInstall(folder: folder, request: request, inputs: inputs, runtimeSteps: steps,
                                    exe: exe, showInSteam: showInSteam, steam: steam)
        }.value
        job.game = made.game
        job.phase = .ready
        return made.steam
    }

    // Everything finish writes or probes, run off the caller's actor.
    private func writeInstall(folder: GameFolder, request: InstallRequest, inputs: InstallInputs,
                              runtimeSteps: [RuntimeStep], exe: URL, showInSteam: Bool,
                              steam: SteamShortcuts?) throws -> (game: InstalledGame, steam: SteamShortcuts.Outcome?) {
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
        try GameLauncher.write(exe: exe, folder: folder, wine: wine, backend: backend)
        var game = InstalledGame(
            id: folder.root.lastPathComponent, name: request.name, appID: request.appID, gogID: request.gogID,
            runnerID: inputs.runnerID, graphics: backend.rawValue,
            wineVersion: runner.version, wineRunnerKind: runner.kind.rawValue,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: exe.path(percentEncoded: false), installedAt: Date(),
            installerFolder: request.source.path(percentEncoded: false),
            redistributables: runtimeSteps.filter { $0.status == .installed }.map(\.verb),
            gameFolder: request.importing.flatMap { $0.copy ? nil : $0.folder.path(percentEncoded: false) }
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
        job.phase = .stopped
        if let folder = job.folder, !folder.isFinished,
           FileManager.default.fileExists(atPath: folder.attempt.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: folder.root)
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
