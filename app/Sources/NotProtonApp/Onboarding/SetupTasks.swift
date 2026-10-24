// Onboarding's Continue button kicks its work off in the background: the runner
// download + prefix-template first boot, console core downloads, a dropped
// toolkit image import. The tasks outlive the sheet and report through
// `activity`, which the activity slot picks up as .setup.

import Foundation
import Observation

struct SetupActivity: Equatable, Sendable {
    let title: String       // what is being worked on
    let label: String       // where it is now
    var fraction: Double?   // nil = indeterminate
}

@MainActor
@Observable
final class SetupTasks {

    struct Status: Equatable, Sendable {
        var started = false
        var working = false
        var done = false
        var detail: String?
        var problem: String?
    }

    private(set) var runner = Status()
    private(set) var runnerTitle = ""
    @ObservationIgnored var didFinish: @MainActor (String) -> Void = { _ in }
    private(set) var cores: [String: Status] = [:]
    private(set) var toolkit = Status()
    private(set) var toolkitVersion: String?

    @ObservationIgnored let installRunner: @Sendable (RunnerManifest.Build) async throws -> Void
    @ObservationIgnored let bootTemplate: @Sendable (RunnerManifest.Build) async throws -> Void
    @ObservationIgnored let addCore: @Sendable (String) async throws -> Void
    @ObservationIgnored let importToolkit: @Sendable (URL) async throws -> String
    @ObservationIgnored private var runnerTask: Task<Void, Never>?
    @ObservationIgnored private var coresTask: Task<Void, Never>?
    @ObservationIgnored private var toolkitTask: Task<Void, Never>?

    init(
        installRunner: @escaping @Sendable (RunnerManifest.Build) async throws -> Void = { _ in },
        bootTemplate: @escaping @Sendable (RunnerManifest.Build) async throws -> Void = { _ in },
        addCore: @escaping @Sendable (String) async throws -> Void = { _ in },
        importToolkit: @escaping @Sendable (URL) async throws -> String = { _ in "" }
    ) {
        self.installRunner = installRunner
        self.bootTemplate = bootTemplate
        self.addCore = addCore
        self.importToolkit = importToolkit
    }

    var anythingWorking: Bool {
        runner.working || toolkit.working || cores.values.contains(where: \.working)
    }

    var activity: SetupActivity? {
        if runner.working {
            return SetupActivity(title: runnerTitle,
                                 label: runner.detail ?? String(localized: "Working"),
                                 fraction: nil)
        }
        if toolkit.working {
            return SetupActivity(title: String(localized: "Game Porting Toolkit"),
                                 label: toolkit.detail ?? String(localized: "Working"),
                                 fraction: nil)
        }
        if cores.values.contains(where: \.working) {
            let done = cores.values.filter(\.done).count
            return SetupActivity(title: String(localized: "Console cores"),
                                 label: String(localized: "Downloading"),
                                 fraction: cores.isEmpty ? nil : Double(done) / Double(cores.count))
        }
        return nil
    }

    // MARK: Runner download + prefix-template first boot

    func startRunner(_ build: RunnerManifest.Build, alreadyInstalled: Bool) {
        guard !runner.working, !runner.done else { return }
        runnerTitle = build.title
        runner = Status(started: true, working: true,
                        detail: alreadyInstalled
                            ? String(localized: "Preparing the Windows environment")
                            : String(localized: "Downloading"))
        runnerTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !alreadyInstalled {
                    try await self.installRunner(build)
                    self.runner.detail = String(localized: "Preparing the Windows environment")
                }
                try await self.bootTemplate(build)
                self.runner.working = false
                self.runner.done = true
                self.didFinish("runner")
            } catch let failure as StepFailure {
                self.runner.working = false
                self.runner.problem = failure.detail
            } catch {
                self.runner.working = false
                self.runner.problem = error.localizedDescription
            }
        }
    }

    // MARK: Console cores

    // Ids already done or in flight are not downloaded again; a failed one retries.
    func startCores(_ ids: [String]) {
        let pending = ids.filter { id in
            guard let status = cores[id] else { return true }
            return !status.working && !status.done
        }
        guard !pending.isEmpty else { return }
        for id in pending {
            cores[id] = Status(started: true, working: true, detail: String(localized: "Downloading"))
        }
        coresTask = Task { [weak self] in
            guard let self else { return }
            for id in pending where !Task.isCancelled {
                do {
                    try await self.addCore(id)
                    self.cores[id]?.working = false
                    self.cores[id]?.done = true
                    self.didFinish("core:" + id)
                } catch let failure as StepFailure {
                    self.cores[id]?.working = false
                    self.cores[id]?.problem = failure.detail
                } catch {
                    self.cores[id]?.working = false
                    self.cores[id]?.problem = error.localizedDescription
                }
            }
        }
    }

    func retryCore(_ id: String) {
        startCores([id])
    }

    // MARK: Game Porting Toolkit image

    func importToolkitImage(_ dmg: URL) {
        guard !toolkit.working, !toolkit.done else { return }
        toolkit = Status(started: true, working: true,
                         detail: String(localized: "Copying D3DMetal from the image"))
        toolkitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let version = try await self.importToolkit(dmg)
                self.toolkit.working = false
                self.toolkit.done = true
                self.toolkitVersion = version
                self.didFinish("toolkit")
            } catch let failure as StepFailure {
                self.toolkit.working = false
                self.toolkit.problem = failure.detail
            } catch {
                self.toolkit.working = false
                self.toolkit.problem = error.localizedDescription
            }
        }
    }
}
