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
    @ObservationIgnored let titles = TitleIndex()
    @ObservationIgnored var compat: @MainActor () async -> CompatData?
    // Steam store search, the app-ID fallback when the compatibility data finds nothing
    @ObservationIgnored var lookup = SteamLookup()
    // A game's name leaves the Mac for Steam only when this says the online lookups choice allows it
    @ObservationIgnored var lookupsAllowed: @MainActor () -> Bool = { false }
    // A wineserver session on the game's prefix means it is running; injectable so tests stay off lsof.
    // It runs a process, so only refreshBusy calls it, off the main actor.
    @ObservationIgnored var isPrefixInUse: @Sendable (GameFolder) -> Bool = {
        PrefixStore.isInUse(root: $0.root, pfx: $0.prefix)
    }
    // The last off-thread answer per game: menus read it, so they never wait on lsof.
    private(set) var busyGames: Set<String> = []
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
        isSheetPresented = true
    }

    func enqueue(_ job: InstallJob) {
        jobs.append(job)
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
            guard let next = job.inputs.applying(fix, runners: engine.runnerIDs()) else { continue }
            job.tried.append(fix)
            job.inputs = next
        }
        job.phase = .waiting
        pump()
    }

    func requeue(_ job: InstallJob) {
        guard job.phase == .failed || job.phase == .stopped else { return }
        job.phase = .waiting
        pump()
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
        let probe = isPrefixInUse
        Task.detached { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            var found: [String: Bool] = [:]
            for game in games {
                guard let folder = GameFolder.of(game, in: installs) else { continue }
                found[game.id] = probe(folder)
            }
            await self?.noteBusy(found)
        }
    }

    private func noteBusy(_ found: [String: Bool]) {
        for (id, busy) in found {
            if busy { busyGames.insert(id) } else { busyGames.remove(id) }
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
        }
        pump()
    }
}
