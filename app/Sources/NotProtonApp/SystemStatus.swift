import AppKit
import CartoucheIdentity
import Foundation
import Observation
import UniformTypeIdentifiers

enum AppVersion {
    static let fallback = "0.1.0-dev"

    static var bundled: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }
}

struct StatusSnapshot: Sendable {
    var steam: SteamDeployment
    var steamRunning: Bool
    var updateBlocked: Bool
    var crossOver: [CrossOverInstall]
    var crossOverLicense: [String: CrossOverLicense.Status] = [:]
    var runner: RunnerState
    var payload: PayloadState
    var installedRunners: [RunnerBuild] = []
    var orphanedRunners: [String] = []
    var damagedRunners: [String] = []
    var installContent: DeploymentContent.Status = .unchecked
    var runners: [Runner] = []
    var compatibilityTools: [InstalledTool] = []
    // This app family once finished an install here (install-build.json)
    var buildRecorded = false
    var steamIntegrationVersion: String? = nil

    static func capture(bundledVersion: String) -> StatusSnapshot {
        let registry = RunnerRegistry.refresh(free: .standard)
        var licenses: [String: CrossOverLicense.Status] = [:]
        for install in registry.installs where install.isUsable {
            licenses[install.id] = CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }

        return StatusSnapshot(
            steam: SteamBundle.deployment(bundledVersion: bundledVersion),
            steamRunning: SteamBundle.isRunning,
            updateBlocked: UpdateBlock.isPresent(),
            crossOver: registry.installs,
            crossOverLicense: licenses,
            runner: registry.state,
            payload: PayloadInspector.inspect(builds: registry.installed),
            installedRunners: registry.installed,
            orphanedRunners: registry.orphaned,
            damagedRunners: registry.damaged,
            installContent: DeploymentContent.current(version: bundledVersion),
            runners: registry.runners,
            compatibilityTools: RunnerRegistry.compatibilityTools(),
            buildRecorded: FileManager.default.fileExists(
                atPath: DeploymentContent.record(beside: SupportPaths.deployedVersion).path(percentEncoded: false)),
            steamIntegrationVersion: (try? DeploymentContent.readBuild(
                at: DeploymentContent.record(beside: SupportPaths.deployedVersion)))?.integrationVersion
        )
    }
}

@MainActor
@Observable
final class SystemStatus {

    var snapshot: StatusSnapshot?
    var isRefreshing = false
    var activity: String?
    var outcome: String?
    private(set) var failure: String?
    private(set) var failureRemedy: Remedy?

    private var runInFlight = false
    @ObservationIgnored var refreshAfterRun: @MainActor (SystemStatus) async -> Void = { await $0.refresh() }
    private var checkingLicense = false

    var isBusy: Bool { activity != nil || runInFlight || checkingLicense }
    var isIdle: Bool { !isBusy && !isRefreshing }
    var canInstall: Bool { isIdle && snapshot?.installContent.blocksInstallation != true }

    // Only Repair replaces a Steam dylib that this account's build record does not name
    var needsRepairInSteam: Bool {
        if case .mismatchedDylib? = snapshot?.installContent { return true }
        return false
    }

    private(set) var upkeep: SteamUpkeep.State = .idle
    @ObservationIgnored var upkeepDefaults: UserDefaults = .standard
    @ObservationIgnored var refreshStatus: @MainActor (SystemStatus) async -> Void = { await $0.refresh() }
    @ObservationIgnored var upkeepInstall: @MainActor (SystemStatus, _ repairing: Bool) async -> Void = {
        await $0.installAutomatically(repairing: $1)
    }
    // Set by the app: the library reloads once Steam has this app's build again
    @ObservationIgnored var onUpkeepInstalled: @MainActor () async -> Void = {}
    @ObservationIgnored private var upkeepInFlight = false
    @ObservationIgnored private var upkeepFailed = false
    @ObservationIgnored private var lastUpkeepCheck: Date?

    // The automatic upkeep owns this state, so no install or repair button is offered for it
    var updatesItself: Bool {
        upkeep == .waitingForQuit || upkeep == .due || upkeep == .updating
    }

    enum Confirmation: Identifiable, Hashable {
        case replaceSteam
        case blockUpdates
        case installUnlicensed
        case toolUnlicensed
        case removeBuild
        case removeEverything
        case quitSteam

        var id: Self { self }
    }

    var pendingConfirmation: Confirmation?
    private(set) var pendingSteamAction: SteamIntegrationLine.Action?
    private(set) var pendingRepair = false
    private(set) var steamStoppedByRun = false
    var generation = 0

    func beginRun(_ label: String) -> Int {
        activity = label
        AppLog.note("run begin: \(label)")
        return generation
    }

    func report(_ run: Int, _ label: String) {
        guard run == generation else { return }
        activity = label
        AppLog.note("run step: \(label)")
    }

    func endRun() {
        generation += 1
        activity = nil
        AppLog.note("run end\(failure == nil ? "" : " (failed)")")
    }

    private func record(_ error: Error) {
        setFailure(error)
        if let refusal = error as? WriteRefused {
            AppLog.note("run failed: cannot write \(refusal.path)")
        } else {
            AppLog.note("run failed: \(error.localizedDescription)")
        }
    }

    func setFailure(_ message: String) {
        failure = message
        failureRemedy = nil
    }

    func setFailure(_ error: Error) {
        let report = FailureReport([error])
        failure = report?.message
        failureRemedy = report?.remedy
    }

    func clearFailure() {
        failure = nil
        failureRemedy = nil
    }

    var usableCrossOver: CrossOverInstall? {
        snapshot?.crossOver.first(where: \.isUsable)
    }

    var usableCrossOvers: [CrossOverInstall] {
        snapshot?.crossOver.filter(\.isUsable) ?? []
    }

    var repairSource: CrossOverInstall? {
        let builds = snapshot?.runner.builds ?? []
        for wanted in builds {
            let found = usableCrossOvers.first { install in
                if case .supported(let build) = install.support { return build.id == wanted }
                return false
            }
            if let found { return found }
        }
        return nil
    }

    var setupSource: CrossOverInstall? { repairSource ?? usableCrossOver }

    // The manifest's pinned Cartouche Wine build, when this app still offers one.
    nonisolated static var wineToolBuild: RunnerManifest.Build? {
        RunnerManifest.current().builds.first {
            $0.kind == Runner.Kind.wineBuild.rawValue && $0.origin == .cartouche && $0.isPinned
        }
    }

    // Anything that can become a compatibility tool: a usable CrossOver, an
    // installed clone to repair, or the pinned Cartouche Wine download.
    var canSetUpTool: Bool {
        setupSource != nil || !(snapshot?.runner.builds.isEmpty ?? true) || Self.wineToolBuild != nil
    }

    func checkLicense(for chosen: CrossOverInstall? = nil) async -> CrossOverLicense.Status? {
        guard let install = chosen ?? usableCrossOver else { return nil }
        let status = await Task.detached(priority: .userInitiated) {
            CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }.value
        snapshot?.crossOverLicense[install.id] = status
        return status
    }

    enum Request {
        case install
        case compatibilityTool
    }

    nonisolated static func activationQuestion(
        _ request: Request, licensed: Bool?, runner: RunnerState
    ) -> Confirmation? {
        guard licensed == false else { return nil }
        switch request {
        case .install: return runner == RunnerState.none ? .installUnlicensed : nil
        case .compatibilityTool: return .toolUnlicensed
        }
    }

    func requestInstall(repairing: Bool = false) async {
        guard canInstall else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        if let question = Self.activationQuestion(
            .install,
            licensed: await checkLicense()?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingRepair = repairing
            pendingConfirmation = question
        } else {
            await installIntoSteam(repairing: repairing)
        }
    }

    // The Cartouche line's one action; while Steam runs it asks before quitting Steam.
    func request(_ action: SteamIntegrationLine.Action, quittingSteam: Bool) async {
        guard canInstall else { return }
        if quittingSteam {
            pendingSteamAction = action
            pendingConfirmation = .quitSteam
            return
        }
        await start(action)
    }

    func confirmQuitSteam() async {
        guard let action = pendingSteamAction else { return }
        pendingSteamAction = nil
        await start(action)
    }

    func cancelQuitSteam() {
        pendingSteamAction = nil
    }

    // The installer quits Steam itself, off the main actor, when files Steam holds change.
    private func start(_ action: SteamIntegrationLine.Action) async {
        switch action {
        case .install, .update: await requestInstall()
        case .repair: await requestInstall(repairing: true)
        case .replaceNotProton: await replaceNotProton()
        }
    }

    func openSteam() async {
        steamStoppedByRun = false
        let app = SupportPaths.Steam.app.path(percentEncoded: false)
        await Task.detached(priority: .userInitiated) {
            _ = try? Shell.run("/usr/bin/open", [app])
        }.value
    }

    func requestCompatibilityTool(
        from chosen: CrossOverInstall? = nil, replacingExisting: Bool = false
    ) async {
        guard canInstall else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        let install = chosen ?? setupSource
        if let question = Self.activationQuestion(
            .compatibilityTool,
            licensed: await checkLicense(for: install)?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingConfirmation = question
        } else {
            await setUpRunner(from: install, replacingExisting: replacingExisting)
        }
    }

    private(set) var pendingRemoval: String?

    func requestBuildRemoval(_ build: String) {
        guard canInstall else { return }
        pendingRemoval = build
        pendingConfirmation = .removeBuild
    }

    func cancelBuildRemoval() {
        pendingRemoval = nil
    }

    func removePendingBuild() async {
        guard let build = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(from: RunnerInstaller.removeStep) { _ in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireUnblockedContent()
            let answer = try await Task.detached(priority: .userInitiated) {
                (try RunnerInstaller.removeClone(forBuild: build), SteamBundle.isRunning)
            }.value
            let removed = String(localized: "Removed build \(RunnerRegistry.displayVersion(forID: build)).")
            return answer.0 && answer.1 ? "\(removed) \(Self.toolsRestartHint)" : removed
        }
    }

    func chooseSteam() async {
        let current = SupportPaths.Steam.app
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Select your copy of Steam.")
        panel.directoryURL = current.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = URL(filePath: url.path)

        clearFailure()
        outcome = nil

        func same(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
        }
        guard !same(picked, current) else { return }
        if SupportPaths.Steam.isUnreachable(current) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Steam at \(current.path(percentEncoded: false)) isn't connected.")
            alert.informativeText = String(localized: "If Cartouche is installed there, it will stay installed. Continue anyway?")
            alert.addButton(withTitle: String(localized: "Continue Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            if let refusal = Self.steamChoiceRefusal(picked, current: current) {
                setFailure(refusal)
                AppLog.note("steam choice refused: \(picked.path(percentEncoded: false))")
                return
            }

            if same(picked, SupportPaths.Steam.defaultApp) {
                UserDefaults.standard.removeObject(forKey: SupportPaths.Steam.appPathKey)
            } else {
                UserDefaults.standard.set(picked.path(percentEncoded: false), forKey: SupportPaths.Steam.appPathKey)
            }
        } catch {
            setFailure(error)
            return
        }
        AppLog.note("steam chosen: \(picked.path(percentEncoded: false))")
        // Another copy of Steam waits for the user's own install
        endUpkeep()
        await refresh()
    }

    static func steamChoiceRefusal(
        _ picked: URL, current: URL, insert: String? = SteamBundle.currentInsert()
    ) -> String? {
        guard Bundle(url: picked)?.bundleIdentifier == SteamRepair.valveIdentifier else {
            return String(localized: "\(picked.lastPathComponent) is not Steam.")
        }
        guard !picked.path(percentEncoded: false).contains(":") else {
            return String(localized: "Cartouche cannot use Steam from a folder with a colon in its name.")
        }
        let deployed = SupportPaths.Steam.deployedDylib(inBundle: current).path(percentEncoded: false)
        if let insert, insert.split(separator: ":").contains(Substring(deployed)) {
            return String(localized: "Cartouche is installed in \(current.path(percentEncoded: false)). Use Repair Steam to remove it before choosing another copy of Steam.")
        }
        return nil
    }

    private static let toolsRestartHint = String(localized: "Restart Steam to update its list of compatibility tools.")

    private func runnerOutcome(_ result: RunnerSetup.Outcome) async -> String {
        if result.stagedNothing { return String(localized: "Compatibility tool is already set up.") }
        guard result.toolsChanged else { return String(localized: "Compatibility tool ready.") }
        let running = await Task.detached(priority: .utility) { SteamBundle.isRunning }.value
        return running
            ? String(localized: "Compatibility tool ready. \(Self.toolsRestartHint)")
            : String(localized: "Compatibility tool ready.")
    }

    func perform(
        from first: String,
        _ body: (_ progress: @escaping @Sendable (String) -> Void) async throws -> String?
    ) async {
        guard !runInFlight else {
            AppLog.note("run refused: '\(first)' overlaps a run already in flight")
            return
        }
        runInFlight = true
        defer { runInFlight = false }

        clearFailure()
        outcome = nil
        steamStoppedByRun = false
        let run = beginRun(first)
        defer { endRun() }

        do {
            outcome = try await body { label in
                Task { @MainActor in self.report(run, label) }
            }
        } catch {
            record(error)
        }

        await refreshAfterRun(self)
    }

    private func setUpRunner(from install: CrossOverInstall?, replacingExisting: Bool = false) async {
        guard let install else {
            // No CrossOver: repair installed clones in place, or set up the
            // Cartouche Wine download as the compatibility tool.
            let builds = (snapshot?.runner.builds ?? []).compactMap { RunnerRegistry.build(id: $0) }
            if !builds.isEmpty {
                await repatchRunners(builds)
            } else {
                await installWineRunner()
            }
            return
        }

        await perform(from: RunnerSetup.Phase.cloning.label) { progress in
            if case .supported(let build) = install.support,
               let index = snapshot?.runners.firstIndex(where: { $0.id == build.id }) {
                snapshot?.runners[index].apply(.install)
            }
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: replacingExisting) {
                    progress($0.label)
                }
            }.value

            return await runnerOutcome(result)
        }
    }

    // Re-stage and re-patch installed clones; each one's own files prove the license.
    private func repatchRunners(_ builds: [RunnerBuild]) async {
        await perform(from: RunnerSetup.Phase.staging.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let last = try await Task.detached(priority: .userInitiated) {
                try builds.map { try RunnerSetup.prepare($0, report: { progress($0.label) }) }.last
            }.value
            guard let last else { return nil }
            return await runnerOutcome(last)
        }
    }

    // No CrossOver needed: fetch the pinned Cartouche Wine build if absent, patch
    // it for Steam and register its compatibility tools.
    private func installWineRunner() async {
        await perform(from: WineRunnerInstaller.step) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let build = Self.wineToolBuild
            let hint = Self.toolsRestartHint
            return try await Task.detached(priority: .userInitiated) {
                guard let build else {
                    throw StepFailure(
                        step: RunnerSetup.prepareStep,
                        detail: String(localized: "No supported copy of CrossOver found."))
                }
                var downloaded = false
                if !WineRunnerInstaller.isInstalled(build.id) {
                    progress(WineRunnerInstaller.step)
                    _ = try await WineRunnerInstaller.install(build)
                    downloaded = true
                }
                let result = try RunnerSetup.prepareWine(build, report: { progress($0.label) })
                if result.installed.wroteNothing && !result.toolsChanged && !downloaded {
                    return String(localized: "Compatibility tool is already set up.")
                }
                let running = SteamBundle.isRunning
                return result.toolsChanged && running
                    ? String(localized: "Compatibility tool ready. \(hint)")
                    : String(localized: "Compatibility tool ready.")
            }.value
        }
    }

    func fetchValveBinaries() async {
        guard canInstall else { return }
        await perform(from: ValveFetcher.Phase.verifying.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await Task.detached(priority: .userInitiated) {
                try await ValveFetcher.run { progress($0.label) }
            }.value
            return result.wroteNothing ? nil : String(localized: "Downloaded missing components.")
        }
    }

    private static let restartHint = String(localized: "Steam was stopped, so start it again.")

    private static let toolNotActivated =
        String(localized: "The compatibility tool was not set up because CrossOver is not activated.")

    private func requireInstallableContent() async throws {
        try await requireUnblockedContent()
        let running = await Task.detached(priority: .utility) {
            RunnerRegistry.clonedBuilds().contains {
                RunnerInstaller.isRunning(from: SupportPaths.runnerRoot(forBuild: $0))
            }
        }.value
        guard !running else {
            throw StepFailure(step: SteamInstaller.step, detail: String(localized: "A game or Wine tool is running. Quit it before updating Cartouche."))
        }
    }

    private func requireUnblockedContent() async throws {
        let version = AppVersion.bundled
        let content = await Task.detached(priority: .utility) {
            DeploymentContent.current(version: version)
        }.value
        snapshot?.installContent = content
        guard !content.blocksInstallation else {
            throw StepFailure(step: SteamInstaller.step,
                              detail: String(localized: "Installation is blocked. Refresh Status and use the Cartouche app that installed this build."))
        }
    }

    func installIntoSteam(repairing: Bool = false) async {
        pendingRepair = false
        await installIntoSteam(replacingNotProton: false, replacingUnrecordedDylib: repairing)
    }

    // Repair puts this app's build in Steam even when Steam's dylib is not the recorded one.
    func repairInSteam() async {
        await installIntoSteam(repairing: true)
    }

    // The user clicked Replace NotProton: the same install, with the takeover of the
    // bundle it injects as its first step.
    func replaceNotProton() async {
        await installIntoSteam(replacingNotProton: true)
    }

    // The upkeep's install: the same run, except that a Steam which started meanwhile fails it instead of being quit
    func installAutomatically(repairing: Bool) async {
        await installIntoSteam(replacingNotProton: false, replacingUnrecordedDylib: repairing,
                               stopClient: Self.leaveSteamRunning)
    }

    nonisolated static let leaveSteamRunning: SteamInstaller.ClientStopper = { _, _ in
        guard !SteamBundle.isRunning else {
            throw StepFailure(step: SteamInstaller.step, detail: String(localized: "Steam is running, please close Steam."))
        }
        return false
    }

    private func installIntoSteam(
        replacingNotProton: Bool, replacingUnrecordedDylib: Bool = false,
        stopClient: @escaping SteamInstaller.ClientStopper = SteamInstaller.stopTheClient
    ) async {
        await perform(from: InstallPhase.checkingPayload.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.run(
                    holdingInstallationLock: true, replacingNotProton: replacingNotProton,
                    replacingUnrecordedDylib: replacingUnrecordedDylib,
                    stopClient: stopClient,
                    report: { progress($0.label) })
            }.value
            steamStoppedByRun = result.stoppedClient

            var parts = [result.replacedNotProton
                ? String(localized: "Cartouche replaced NotProton in Steam.")
                : String(localized: "Cartouche successfully installed.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            let install = usableCrossOver
            let state = await Task.detached(priority: .userInitiated) {
                (runner: RunnerRegistry.state(),
                 payload: PayloadInspector.inspect(),
                 license: install.map { CrossOverLicense.check(crossOverRoot: $0.crossOverRoot) })
            }.value

            if let install, state.license?.licensed == true, state.runner == .none {
                progress(String(localized: "Setting up compatibility tool"))
                _ = try await Task.detached(priority: .userInitiated) {
                    try RunnerSetup.run(from: install) { progress($0.label) }
                }.value
            } else if install != nil, state.license?.licensed == false, state.runner == .none {
                parts.append(Self.toolNotActivated)
            }

            let valve = try ValvePackageManifest.bundled()
            let needsValve = await Task.detached(priority: .utility) {
                valve.files.contains { Digest.sha256IfPresent(SupportPaths.bridge.appending(path: $0.bridgePath)) != $0.sha256 }
            }.value
            if needsValve {
                progress(String(localized: "Downloading missing components"))
                _ = try await Task.detached(priority: .userInitiated) {
                    try await ValveFetcher.run { progress($0.label) }
                }.value
            }

            try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.finish(result)
            }.value
            upkeepDefaults.set(true, forKey: SteamUpkeep.setUpKey)
            upkeepFailed = false

            return parts.joined(separator: " ")
        }
    }

    func setUpdateBlock(_ blocked: Bool) async {
        await perform(from: blocked ? String(localized: "Blocking Steam client updates")
                                    : String(localized: "Allowing Steam client updates")) { _ in
            if blocked {
                try UpdateBlock.write()
                return String(localized: "Steam client updates are blocked.")
            }

            try UpdateBlock.remove()
            return String(localized: "Steam client updates are allowed.")
        }
    }

    // The user takes Cartouche out of this Steam, so the upkeep stops putting it back
    private func endUpkeep() {
        upkeepDefaults.set(false, forKey: SteamUpkeep.setUpKey)
        upkeepFailed = false
        upkeep = .idle
    }

    func repairSteam() async {
        endUpkeep()
        await perform(from: RepairPhase.checking.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try await Task.detached(priority: .userInitiated) {
                try await SteamRepair.run(report: { progress($0.label) })
            }.value

            var parts = [String(localized: "Steam restored to its original state.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            return parts.joined(separator: " ")
        }
    }

    func resetControllerPermission() async {
        await perform(from: String(localized: "Resetting Steam's controller permission")) { _ in
            let answer = await Task.detached(priority: .userInitiated) {
                (SteamInstaller.failedInputAccessResets(), SteamBundle.isRunning)
            }.value
            guard answer.0.isEmpty else {
                throw StepFailure(
                    step: String(localized: "Reset controller permission"),
                    detail: String(localized: "macOS did not reset \(answer.0.joined(separator: ", ")) for Steam.")
                )
            }
            return answer.1
                ? String(localized: "Controller permission reset. Restart Steam so macOS asks again.")
                : String(localized: "Controller permission reset. macOS asks again when Steam starts.")
        }
    }

    func removeEverything() async {
        endUpkeep()
        await perform(from: UninstallPhase.stoppingClient.label) { progress in
            let result = try await Task.detached(priority: .userInitiated) {
                try await Uninstall.run(report: { progress($0.label) })
            }.value

            if let partial = result.partialRemoval { return partial }
            if result.leftSteamForOtherTool {
                return String(localized: "Cartouche has been removed. Steam was left as it is, because another tool also uses it.")
            }
            return result.steamNeedsRedownload
                ? String(localized: "Cartouche has been removed. Steam could not be restored. Reinstall Steam from steampowered.com before using it again.")
                : String(localized: "Cartouche has been removed.")
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let version = AppVersion.bundled
        let captured = await Task.detached(priority: .userInitiated) {
            StatusSnapshot.capture(bundledVersion: version)
        }.value
        snapshot = captured
        planUpkeep(captured)
        AppLog.note(captured)
        await refreshRunnerStorage(cleanTemplates: !captured.installContent.blocksInstallation)
    }

    // A check hashes Cartouche's files, so app activation asks at most every few minutes
    func keepSteamIntegrationCurrentOnActivation(now: Date = Date()) async {
        guard (upkeepDefaults.object(forKey: SteamUpkeep.setUpKey) as? Bool) != false else { return }
        if upkeep != .waitingForQuit, let last = lastUpkeepCheck, now.timeIntervalSince(last) < 300 { return }
        await keepSteamIntegrationCurrent()
    }

    private func planUpkeep(_ snapshot: StatusSnapshot) {
        guard upkeep != .updating else { return }
        let decision = SteamUpkeep.decide(
            setUpBefore: SteamUpkeep.wasSetUp(snapshot, defaults: upkeepDefaults),
            failedBefore: upkeepFailed, snapshot: snapshot)
        if decision == .nothing { upkeepFailed = false }
        upkeep = SteamUpkeep.state(for: decision)
    }

    // Read-only status refresh. Installing or updating the integration requires the explicit Settings action.
    func keepSteamIntegrationCurrent() async {
        guard !upkeepInFlight, !isBusy else { return }
        upkeepInFlight = true
        defer { upkeepInFlight = false }
        lastUpkeepCheck = Date()
        await refreshStatus(self)
        if let snapshot { planUpkeep(snapshot) }
        // Checking on activation or Steam quitting never installs or replaces files.
    }

    private(set) var runnerSizes: [String: Int64] = [:]
    private(set) var templateSizes: [String: [CompatTool.Flavor: Int64]] = [:]
    private(set) var templateCleanupFailure: String?
    private(set) var bridgeCopyBytes: Int64 = 0

    func refreshRunnerStorage(
        runners: URL = SupportPaths.runners, libraries: [SteamLibrary] = PrefixStore.libraries(),
        cleanTemplates: Bool = true,
        acquireInstallationLock: @escaping @Sendable () throws -> DeploymentContent.InstallationLock = {
            try DeploymentContent.acquireInstallationLock()
        }
    ) async {
        let known = runnerSizes
        let measured = await Task.detached(priority: .utility) {
            let failures: [StepFailure]
            if cleanTemplates, let lock = try? acquireInstallationLock() {
                defer { lock.release() }
                RunnerInstaller.removeLeftoverRemovals(runners: runners)
                failures = RunnerInstaller.removeStalePrefixTemplates(
                    runners: runners, libraries: libraries, reportBusy: false)
            } else {
                failures = []
            }
            var sizes: [String: Int64] = [:]
            var templates: [String: [CompatTool.Flavor: Int64]] = [:]
            let bridgeCopies = libraries.reduce(Int64(0)) { total, library in
                let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                var info = stat()
                guard lstat(folder.path(percentEncoded: false), &info) == 0,
                    info.st_mode & S_IFMT == S_IFDIR else { return total }
                return total + PrefixStore.directoryBytes(
                    folder.appending(path: SupportPaths.bridgeCacheFolder), metric: .allocated)
            }
            for build in RunnerRegistry.clonedBuilds(in: runners) {
                sizes[build] = known[build] ?? RunnerRegistry.cloneSize(forBuild: build, runners: runners)
                templates[build] = libraries.reduce(into: [:]) { totals, library in
                    let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    var info = stat()
                    guard lstat(folder.path(percentEncoded: false), &info) == 0,
                        info.st_mode & S_IFMT == S_IFDIR else { return }
                    for flavor in CompatTool.Flavor.allCases {
                        let template = SupportPaths.prefixTemplate(forBuild: build, flavor: flavor, in: library)
                        totals[flavor, default: 0] += PrefixStore.directoryBytes(template, metric: .allocated)
                    }
                }
            }
            return (sizes, templates, failures, bridgeCopies)
        }.value
        runnerSizes = measured.0
        templateSizes = measured.1
        templateCleanupFailure = measured.2.isEmpty ? nil : measured.2.map(\.detail).joined(separator: "\n")
        bridgeCopyBytes = measured.3
    }
}
