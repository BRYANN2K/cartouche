// Everything it starts is a Wine process or a macOS tool; nothing from the installer's folder runs outside Wine.

import Foundation
import InstallerKit

struct InstallEngine: Sendable {

    var installs: URL = GameFolder.installs
    var runners: URL = SupportPaths.runners
    var registry: @Sendable () -> RunnerRegistry = { RunnerRegistry.refresh(free: .standard) }
    var environment: [String: String] = SetupEnvironment.base
    var policy = InstallRun.Policy()
    var keepAwake = true
    var winetricks: @Sendable (_ verbs: [String], _ prefix: URL, _ wine: WineRunner, _ log: URL) async throws -> InstallRun
        = InstallerWinetricks.run

    func runnerIDs() -> [String] { InstallRunners.choices(registry()).map(\.id) }

    @MainActor
    func run(_ job: InstallJob) async {
        let request = job.request
        let inputs = job.inputs
        job.problem = nil
        job.diagnosis = nil
        job.progress = InstallProgress(expected: request.expectedBytes)
        job.run = nil

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

        job.phase = .preparing
        let registry = registry()
        guard let runner = registry.runner(id: inputs.runnerID) ?? InstallRunners.choices(registry).first,
              let wine = InstallRunners.wine(for: runner, runners: runners) else {
            job.fail(String(localized: "No runner is set up for installs. Set one up in Runners first."))
            return
        }
        job.inputs.runnerID = runner.id

        let folder: GameFolder
        do {
            folder = try GameFolder.fresh(for: request.name, in: installs)
            job.folder = folder
            if let create = try WineBootstrap.createRun(wine: wine, prefix: folder.prefix, base: environment,
                                                     log: folder.root.appending(path: "prefix.log")) {
                job.run = create
                try create.start()
                let status = await create.exitStatus()
                if create.wasStopped || Task.isCancelled {
                    stopped(job)
                    return
                }
                guard status == 0 else {
                    job.fail(String(localized: "The prefix could not be created (status \(status))."))
                    return
                }
                await waitForWine(wine, prefix: folder.prefix)
            }
            if inputs.shortSource { try WineInstall.mapSource(request.source, prefix: folder.prefix) }
        } catch {
            job.fail(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { stopped(job); return }

        job.phase = .installing
        let launch = WineInstall.runSetup(request.setup, runner: wine, prefix: folder.prefix, inputs: job.inputs, base: environment)
        let run = InstallRun(launch, output: folder.wineOutput)
        job.run = run
        do { try run.start() } catch {
            job.fail(error.localizedDescription)
            return
        }
        if keepAwake { Self.keepAwake(while: run.pid) }

        let installDir = WinePath.unix(job.inputs.installDir, prefix: folder.prefix) ?? folder.prefix
        let cls = CLSPatches(prefix: folder.prefix, inputs: job.inputs)
        let status = await run.monitor(folder: installDir, expected: request.expectedBytes, policy: policy,
                                       onTick: { cls.apply() }) { progress in
            Task { @MainActor in if job.phase == .installing { job.progress = progress } }
        }
        await waitForWine(wine, prefix: folder.prefix)
        if run.wasStopped || Task.isCancelled {
            stopped(job)
            return
        }

        let logFile = WinePath.unix(job.inputs.log, prefix: folder.prefix)
        let log = logFile.flatMap(InstallLog.read)
        if let logFile { try? FileManager.default.copyItem(at: logFile, to: folder.root.appending(path: "install.log")) }
        let diagnosis = InstallLog.diagnose(exitCode: status, log: log)
        guard diagnosis.succeeded else {
            job.diagnosis = diagnosis
            if case .cancelled = diagnosis.kind {
                stopped(job)
                return
            }
            job.phase = .failed
            return
        }

        let gog = GOGInfo.find(in: installDir)
        let primary = gog.flatMap { found in found.info.primaryExe.map { found.url.deletingLastPathComponent().appending(path: $0) } }
        let scan = ExeDetector.scan(installFolder: installDir, prefix: folder.prefix, primary: primary)
        job.installFolder = scan.installFolder
        job.candidates = scan.candidates

        // The installer's own runtime installers are not run: winetricks installs the Wine equivalents.
        job.redistributables = Redistributables.find(in: scan.installFolder)
        let verbs = Redistributables.verbs(job.redistributables)
        if !verbs.isEmpty {
            guard !Task.isCancelled else { stopped(job); return }
            job.phase = .redistributables
            let log = folder.root.appending(path: PrefixTools.winetricksLogName)
            do {
                let run = try await winetricks(verbs, folder.prefix, wine, log)
                job.run = run
                try run.start()
                let status = await run.exitStatus()
                if run.wasStopped || Task.isCancelled { stopped(job); return }
                job.redistributablesInstalled = status == 0
                if status != 0 {
                    AppLog.note("installer: winetricks \(verbs) stopped with status \(status); its output is in \(log.path(percentEncoded: false))")
                }
            } catch {
                if Task.isCancelled { stopped(job); return }
                AppLog.note("installer: winetricks \(verbs) failed: \(error.localizedDescription)")
                job.redistributablesInstalled = false
            }
            await waitForWine(wine, prefix: folder.prefix)
        }
        job.progress.fraction = 1
        job.phase = .choosing
    }

    @MainActor
    func finish(_ job: InstallJob, exe: URL, showInSteam: Bool, steam: SteamShortcuts = SteamShortcuts()) throws -> SteamShortcuts.Outcome? {
        guard let folder = job.folder else { return nil }
        let registry = registry()
        let runner = registry.runner(id: job.inputs.runnerID)
        guard let wine = runner.flatMap({ InstallRunners.wine(for: $0, runners: runners) }) else {
            throw StepFailure(step: String(localized: "Write the game's launcher"),
                              detail: String(localized: "The runner that installed the game is not set up anymore."))
        }
        try GameLauncher.write(exe: exe, folder: folder, wine: wine, backend: .wined3d)
        // The setup defaults to what the install ran: the installer's runner, plain Wine (wined3d)
        var game = InstalledGame(
            id: folder.root.lastPathComponent, name: job.request.name, appID: job.request.appID, gogID: job.request.gogID,
            runnerID: job.inputs.runnerID, graphics: GraphicsBackend.wined3d.rawValue,
            wineVersion: runner?.version, wineRunnerKind: runner?.kind.rawValue,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: exe.path(percentEncoded: false), installedAt: Date(),
            installerFolder: job.request.source.path(percentEncoded: false),
            redistributables: Redistributables.verbs(job.redistributables)
        )
        var outcome: SteamShortcuts.Outcome?
        if showInSteam {
            outcome = steam.add(name: game.name, launcher: folder.launcher, startDir: exe.deletingLastPathComponent())
            game.steamShortcut = outcome == .added || outcome == .alreadyThere
        }
        try InstalledGames.save(game, in: folder)
        job.game = game
        job.phase = .ready
        return outcome
    }

    @MainActor
    func stop(_ job: InstallJob) {
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
