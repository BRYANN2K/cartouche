// Owns every install, one running at a time (decompression takes the whole
// CPU), and the sheet that shows them. The library window hosts the sheet with
// .installSheet(library:) (InstallSheetHost.swift); dropped folders or setup.exe
// files go to open(urls), and the activity card reads activity.

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
    private(set) var jobs: [InstallJob] = []
    let sheet: InstallSheetModel

    @ObservationIgnored var engine: InstallEngine
    @ObservationIgnored var notifier: any InstallNotifying
    // Set by the host so the first finished install offers notifications (P17).
    @ObservationIgnored var permissionFlow: PermissionFlow?
    // Called when a finished install is in the library record, for the library to show it.
    @ObservationIgnored var onGameReady: @MainActor (InstalledGame) -> Void = { _ in }
    // Where game matches come from; the host can pass its CompatibilityModel's data.
    @ObservationIgnored var compat: @MainActor () -> CompatData? = {
        let model = CompatibilityModel()
        model.load()
        return model.data
    }

    init(engine: InstallEngine = InstallEngine(), notifier: (any InstallNotifying)? = nil) {
        self.engine = engine
        let user = UserInstallNotifier()
        self.notifier = notifier ?? user
        self.sheet = InstallSheetModel()
        sheet.center = self
        user.onOpen = { [weak self] id in self?.show(jobID: id) }
    }

    var running: InstallJob? { jobs.first { $0.isRunning } }

    // For the activity card: the running install, or nil.
    var activity: InstallActivity? {
        guard let job = running else { return nil }
        return InstallActivity(title: job.title, fraction: job.progress.fraction, stuck: job.isStuck,
                               waiting: jobs.filter { $0.phase == .waiting }.count)
    }

    // Opens the sheet: on the running install if there is one, else on the drop step,
    // or straight to the analysis of what was dropped.
    func open(_ urls: [URL] = []) {
        if let url = urls.first {
            sheet.reset()
            sheet.analyze(url)
        } else if let job = running ?? jobs.last(where: { $0.phase == .choosing || $0.phase == .failed }) {
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
        guard let next = job.inputs.applying(fix, runners: engine.runnerIDs()) else { return }
        job.tried.append(fix)
        job.inputs = next
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

    func finish(_ job: InstallJob, exe: URL, showInSteam: Bool) throws -> SteamShortcuts.Outcome? {
        let outcome = try engine.finish(job, exe: exe, showInSteam: showInSteam)
        if let game = job.game { onGameReady(game) }
        return outcome
    }

    func forget(_ job: InstallJob) {
        jobs.removeAll { $0 === job }
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
        if job.phase == .choosing {
            if let flow = permissionFlow { NotificationOffer.offer(after: .installFinished, flow: flow) }
            if !isSheetPresented || sheet.job !== job { notifier.installed(name: job.title, job: job.id) }
        }
        pump()
    }
}
