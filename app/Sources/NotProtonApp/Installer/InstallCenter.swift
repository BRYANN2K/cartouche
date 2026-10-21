//// Owns every install, one running at a time (decompression takes the whole CPU), and the sheet that shows them.
//// Dropped folders or setup.exe files go to open(urls); the activity card reads activity.

import Foundation
import InstallerKit
import Observation

struct InstallActivity: Equatable, Sendable {
    let title: String
    let fraction: Double
    let stuck: Bool
    let waiting: Int
}

@MainActor
@Observable
final class InstallCenter {

    static let shared = InstallCenter()

    var isSheetPresented = false
    @ObservationIgnored var showConsoleGames: (@MainActor () -> Void)?
    private(set) var jobs: [InstallJob] = []
    let sheet: InstallSheetModel

    @ObservationIgnored var engine: InstallEngine
    @ObservationIgnored var notifier: any InstallNotifying
    @ObservationIgnored var permissionFlow: PermissionFlow?
    @ObservationIgnored var onGameReady: @MainActor (InstalledGame) -> Void = { _ in }
    // Surfaced to the game-verification presenter: the job's output check found mismatches.
    @ObservationIgnored var onVerificationMismatch: @MainActor (InstallJob) -> Void = { _ in }
    @ObservationIgnored let titles = TitleIndex()
    @ObservationIgnored var compat: @MainActor () async -> CompatData?
    // Steam store search, the app-ID fallback when the compatibility data finds nothing
    @ObservationIgnored var lookup = SteamLookup()
    // A game's name leaves the Mac for Steam only when this says the online lookups choice allows it
    @ObservationIgnored var lookupsAllowed: @MainActor () -> Bool = { false }
    // A wineserver session on the game's prefix means it is running; how busy the
    // session is decides the menu's sibling label. It runs a process, so only
    // refreshBusy calls it, off the main actor.
    @ObservationIgnored var prefixUse: @Sendable (GameFolder) -> PrefixUse = { folder in
        let record = InstalledGames.record(in: folder)
        let installs = folder.root.deletingLastPathComponent()
        let use = PrefixStore.use(
            root: folder.root, pfx: folder.prefix,
            own: record.map { (name: $0.name, root: $0.gameRoot) },
            siblings: InstalledGames.all(in: installs)
                .filter { $0.id != record?.id }
                .map { (name: $0.name, root: $0.gameRoot) })
        // A connected socket fd does not always list under the server's directory, so a
        // helpers-only answer gets one more look for the game's own exe, which argues
        // with its folder path in argv.
        guard use == .sessionOnly, let root = record?.gameRoot else { return use }
        return GameProcesses().pids(installFolder: root).isEmpty ? .sessionOnly : .running(.game)
    }
    // The last off-thread answer per game: menus read it, so they never wait on lsof.
    private(set) var busyGames: Set<String> = []
    // Same deal for the runners a retry could switch to: refreshed off the main actor,
    // so offering or applying a retry fix never waits on a codesign probe.
    private(set) var retryRunners: [String] = []
    // The busy games whose session has no client left: only Wine's helpers keep it up.
    private(set) var sessionOnlyGames: Set<String> = []
    // For each busy game, the client its session still serves: the game's own
    // leftover, a store client or a user-opened program — the menu's Quit names it.
    private(set) var busyClients: [String: SessionResident] = [:]
    // wineserver -w/-k go through these so tests never start a real wineserver.
    @ObservationIgnored var waitServer: @Sendable (URL, [String: String], TimeInterval) async -> Bool = {
        server, env, timeout in await WineServer.drain(server: server, env: env, timeout: timeout)
    }
    @ObservationIgnored var killServer: @Sendable (URL, [String: String]) async -> Void = {
        server, env in await WineServer.kill(server: server, env: env)
    }
    @MainActor private static var compatModel: CompatibilityModel?

    init(engine: InstallEngine = InstallEngine(), notifier: (any InstallNotifying)? = nil) {
        self.engine = engine
        self.compat = {
            if let model = InstallCenter.compatModel { return model.data }
            let model = CompatibilityModel()
            await model.load()
            InstallCenter.compatModel = model
            return model.data
        }
        let user = UserInstallNotifier()
        self.notifier = notifier ?? user
        self.sheet = InstallSheetModel()
        sheet.center = self
        user.onOpen = { [weak self] id in self?.show(jobID: id) }
    }

    var running: InstallJob? { jobs.first { $0.isRunning } }

    var activity: InstallActivity? {
        guard let job = running else { return nil }
        return InstallActivity(title: job.title, fraction: job.progress.fraction, stuck: job.isStuck,
                               waiting: jobs.filter { $0.phase == .waiting }.count)
    }

    func open(_ urls: [URL] = []) {
        if let url = urls.first {
            sheet.reset()
            sheet.analyze(url)
        } else if let job = running ?? jobs.last(where: { $0.phase == .choosing }) {
            sheet.show(job)
        } else if sheet.job.map({ !$0.isRunning && $0.phase != .choosing }) ?? true, sheet.step != .analysis {
            sheet.reset()
        }
        isSheetPresented = true
    }

    func continueInBackground() {
        isSheetPresented = false
    }

    func show(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        sheet.show(job)
        refreshRetryRunners()
        isSheetPresented = true
    }

    func enqueue(_ job: InstallJob) {
        jobs.append(job)
        refreshRetryRunners()
        pump()
    }

    func retry(_ job: InstallJob, with fix: RetryFix) {
        retry(job, fixes: [fix])
    }

    // All fixes of one retry applied to the inputs first, then the job queues once; a waiting or running job is left
    // alone: retrying it would start a second engine run on the same job.
    func retry(_ job: InstallJob, fixes: [RetryFix]) {
        guard job.phase == .failed || job.phase == .stopped else { return }
        for fix in fixes {
            guard let next = job.inputs.applying(fix, runners: retryRunners) else { continue }
            job.tried.append(fix)
            job.inputs = next
        }
        job.phase = .waiting
        pump()
    }

    // The registry scan behind the retry runners checks codesignatures: it waits on
    // processes, so it refreshes detached and the main actor only ever reads the last answer.
    private func refreshRetryRunners() {
        let engine = engine
        Task { [weak self] in await self?.noteRetryRunners(engine.runnerIDs()) }
    }

    private func noteRetryRunners(_ ids: [String]) { retryRunners = ids }

    func requeue(_ job: InstallJob) {
        guard job.phase == .failed || job.phase == .stopped else { return }
        job.phase = .waiting
        pump()
    }

    // The mismatch retry is ADR 0026's standard method: the installer's own shipped helpers with
    // their original settings first, and the real installer guided under Wine as the last resort.
    func retryStandard(_ job: InstallJob) {
        guard job.phase == .failed || job.phase == .stopped else { return }
        guard job.verification?.mismatched.isEmpty == false || job.request.importing != nil else {
            requeue(job)
            return
        }
        job.verificationFallback += 1
        // The retry keeps the job's original inputs — install dir, language, memory share — so the
        // standard method runs what the first run ran.
        var inputs = job.inputs
        inputs.mode = .guided
        if job.request.importing != nil {
            // An import has no installer helpers: the retry copies the folder again.
        } else if job.request.directUnpack != nil, job.verificationFallback == 1 {
            // The installer's own helpers, run with their original settings.
            inputs.externalUnpacker = true
        } else {
            // Last resort: setup itself, guided.
            job.request.directUnpack = nil
            inputs.externalUnpacker = job.request.unpacker != nil
        }
        job.inputs = inputs
        job.diagnosis = nil
        job.problem = nil
        job.phase = .waiting
        pump()
    }

    // Keep Anyway: the job resumes past the mismatch; its record stays not verified and the
    // files are logged. The engine owns the resume.
    func keepAnyway(_ job: InstallJob) {
        guard job.phase == .failed, job.verification?.mismatched.isEmpty == false else { return }
        let engine = engine
        job.task = Task { [weak self] in
            await engine.resumeAfterMismatch(job)
            self?.ended(job)
        }
    }

    func stop(_ job: InstallJob) {
        if job.phase == .waiting {
            job.phase = .stopped
            jobs.removeAll { $0 === job }
        } else {
            engine.stop(job)
        }
    }

    func finish(_ job: InstallJob, exe: URL, showInSteam: Bool) async throws -> SteamShortcuts.Outcome? {
        let outcome = try await engine.finish(job, exe: exe, showInSteam: showInSteam)
        if let game = job.game { onGameReady(game) }
        return outcome
    }

    func forget(_ job: InstallJob) {
        jobs.removeAll { $0 === job }
    }

    // The job building this game, while it still has work left.
    func job(for game: Game) -> InstallJob? {
        guard game.id.hasPrefix("installer:") else { return nil }
        let slug = String(game.id.dropFirst("installer:".count))
        return jobs.first { job in
            (job.folder?.root.lastPathComponent == slug || job.game?.id == slug)
                && (job.isRunning || job.phase == .waiting || job.phase == .choosing)
        }
    }

    // An install on it or a live prefix: moving its folder to the Trash then would pull the rug out.
    // Cheap and synchronous: the prefix half comes from busyGames, never probed here.
    func isBusy(_ game: Game) -> Bool {
        job(for: game) != nil || busyGames.contains(game.id)
    }

    // The lsof probe that fills busyGames: it spawns a process, so it never runs on the main actor.
    // Called when a panel or the window's games change and after an install or a launch.
    func refreshBusy(for games: [Game], in installs: URL, after delay: Duration = .zero) {
        let probe = prefixUse
        Task.detached { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            var found: [String: PrefixUse] = [:]
            for game in games {
                guard let folder = GameFolder.of(game, in: installs) else { continue }
                found[game.id] = probe(folder)
            }
            await self?.noteBusy(found)
        }
    }

    private func noteBusy(_ found: [String: PrefixUse]) {
        for (id, use) in found {
            if use == .free {
                busyGames.remove(id)
                sessionOnlyGames.remove(id)
                busyClients.removeValue(forKey: id)
            } else {
                busyGames.insert(id)
                if case .running(let resident) = use {
                    sessionOnlyGames.remove(id)
                    busyClients[id] = resident
                } else {
                    sessionOnlyGames.insert(id)
                    busyClients.removeValue(forKey: id)
                }
            }
        }
    }

    // The menu's answer to a stuck "running": wineserver -k on this game's own
    // prefix, never another's, then a fresh probe so removal is offered again.
    func endSession(for game: Game, in installs: URL) {
        let runners = engine.registry().runners
        let runnerRoot = engine.runners
        let kill = killServer
        Task.detached { [weak self] in
            guard let folder = GameFolder.of(game, in: installs),
                  let session = WineSession.of(folder: folder, runners: runners,
                                               runnerRoot: runnerRoot)
            else { return }
            await kill(session.server, session.environment)
            await self?.refreshBusy(for: [game], in: installs, after: .milliseconds(300))
        }
    }

    // A launched game leaves its session's helpers behind: once the launcher's own
    // process is gone the game is over, so the prefix gets a short -w. -k ends what
    // stayed only when it is known leftovers — the exited game's own processes or
    // Wine's services; a store client, another game or a program the user opened
    // keeps its session — then a fresh probe answers the menu.
    func watchSession(_ run: InstallRun, for game: Game, in installs: URL,
                      drain timeout: TimeInterval = WineSession.drain) {
        let runners = engine.registry().runners
        let runnerRoot = engine.runners
        let wait = waitServer
        let kill = killServer
        let probe = prefixUse
        Task.detached { [weak self] in
            _ = await run.exitStatus()
            guard let folder = GameFolder.of(game, in: installs),
                  let session = WineSession.of(folder: folder, runners: runners,
                                               runnerRoot: runnerRoot)
            else { return }
            if await wait(session.server, session.environment, timeout), probe(folder).leftoversOnly {
                await kill(session.server, session.environment)
            }
            await self?.refreshBusy(for: [game], in: installs, after: .milliseconds(300))
        }
    }

    private func pump() {
        guard running == nil, let next = jobs.first(where: { $0.phase == .waiting }) else { return }
        next.phase = .preparing
        let engine = engine
        next.task = Task { [weak self] in
            await engine.run(next)
            self?.ended(next)
        }
    }

    private func ended(_ job: InstallJob) {
        if job.phase == .stopped { jobs.removeAll { $0 === job } }
        // An import picks its program up front, so it ends ready, already in the library.
        if job.phase == .ready, let game = job.game { onGameReady(game) }
        if let game = job.game { refreshBusy(for: [Game(installed: game)], in: engine.installs) }
        if job.phase == .choosing || job.phase == .ready {
            if let flow = permissionFlow { NotificationOffer.offer(after: .installFinished, flow: flow) }
            if !isSheetPresented || sheet.job !== job { notifier.installed(name: job.title, job: job.id) }
        }
        if job.phase == .failed {
            if let flow = permissionFlow { NotificationOffer.offer(after: .installFinished, flow: flow) }
            if !isSheetPresented || sheet.job !== job { notifier.failed(name: job.title, job: job.id) }
            // A failure is what shows the retry fixes: the runner list is freshest now
            refreshRetryRunners()
            if job.verification?.mismatched.isEmpty == false { onVerificationMismatch(job) }
        }
        pump()
    }
}
