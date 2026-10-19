// The one list of runners the app, Steam's tools and the installer read from.
// Features go through here instead of the CrossOver code underneath.

import Foundation

struct RunnerRegistry: Sendable {

    var runners: [Runner] = []

    // CrossOver copies found on disk, in the order setup prefers them.
    var installs: [CrossOverInstall] = []
    // The cloned CrossOver builds as the Status pane sums them up.
    var state: RunnerState = .none
    var installed: [RunnerBuild] = []
    var orphaned: [String] = []
    var damaged: [String] = []

    var offered: [Runner] { runners.filter(\.isOffered) }

    func runner(id: String) -> Runner? {
        runners.first { $0.id == id }
    }

    @discardableResult
    mutating func apply(_ event: Runner.Event, to id: String) -> Bool {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return false }
        return runners[index].apply(event)
    }

    static func refresh(
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        roots: [URL] = CrossOverSource.searchRoots,
        manual: [URL] = CrossOverSource.manualBundles(),
        pins: [RunnerBuild] = SupportedRunners.all,
        fexAvailable: Bool = CompatTool.Flavor.fexAvailable,
        // Free runners (Wine builds, Game Porting Toolkit) are listed after CrossOver when given
        free: FreeRunnerScan? = nil
    ) -> RunnerRegistry {
        let installs = CrossOverSource.discover(roots: roots, manual: manual, pins: pins)
        let installed = RunnerStore.installedBuilds(in: runners, pins: pins)
        let problems = RunnerStore.problems(of: installed, runners: runners) {
            RunnerPatcher.verify(build: $0, root: $1, bridge: bridge)
        }
        let damaged = RunnerStore.damagedClones(in: runners, pins: pins)
        let orphaned = RunnerStore.orphanedClones(in: runners, pins: pins)

        return RunnerRegistry(
            runners: CrossOverSource.runners(
                installs: installs, installed: installed, damaged: damaged, orphaned: orphaned,
                problems: problems, pins: pins, fexAvailable: fexAvailable
            ) + (free?.runners(runners: runners, fexAvailable: fexAvailable) ?? []),
            installs: installs,
            state: RunnerStore.state(of: installed, problems: problems),
            installed: installed,
            orphaned: orphaned,
            damaged: damaged
        )
    }

    // What no longer matches its pin in a runner's copy, file by file. Empty means ready.
    static func verify(
        _ runner: Runner, runners: URL = SupportPaths.runners, bridge: URL = SupportPaths.bridge
    ) -> [String] {
        switch runner.kind {
        case .crossOver:
            guard let build = runner.build else { return [] }
            guard RunnerInstaller.hasClone(forBuild: build.id, runners: runners) else {
                return [CrossOverSource.missingWine]
            }
            return RunnerPatcher.verify(
                build: build, root: SupportPaths.clonedRoot(forBuild: build.id, runners: runners), bridge: bridge)
        case .wineBuild:
            return WineRunnerInstaller.verify(runner.id, runners: runners)
        case .portingToolkit:
            return PortingToolkitSource.verify(version: runner.version, runners: runners)
        }
    }
}

// Reads for features that need one fact rather than the whole list.
extension RunnerRegistry {

    static func state(runners: URL = SupportPaths.runners) -> RunnerState {
        RunnerStore.state(runners: runners)
    }

    static func installedBuilds(in runners: URL = SupportPaths.runners) -> [RunnerBuild] {
        RunnerStore.installedBuilds(in: runners)
    }

    static func clonedBuilds(in runners: URL = SupportPaths.runners) -> [String] {
        RunnerStore.clonedBuilds(in: runners)
    }

    static func cloneSize(forBuild build: String, runners: URL = SupportPaths.runners) -> Int64 {
        RunnerStore.cloneSize(forBuild: build, runners: runners)
    }

    // The tools Steam is offered, as the list file records them.
    static func tools(runners: URL = SupportPaths.runners, file: URL = SupportPaths.toolList) -> [InstalledTool] {
        CompatToolList.installed(runners: runners, file: file)
    }

    static func tools(for builds: [RunnerBuild]) -> [InstalledTool] {
        SupportedRunners.tools(for: builds)
    }

    static func build(id: String) -> RunnerBuild? {
        SupportedRunners.build(id: id)
    }

    static func displayVersion(forID id: String) -> String {
        SupportedRunners.displayVersion(forID: id)
    }

    static var versionList: String { SupportedRunners.versionList }

    // Copies of CrossOver the user picks by hand.

    static func looksLikeCrossOver(_ bundle: URL) -> Bool {
        CrossOverSource.looksLikeCrossOver(bundle)
    }

    static func inspect(bundle: URL) -> CrossOverInstall {
        CrossOverSource.inspect(bundle: bundle)
    }

    static func addManualBundle(_ bundle: URL) {
        CrossOverSource.addManualBundle(bundle)
    }

    static func removeManualBundle(_ bundle: URL) {
        CrossOverSource.removeManualBundle(bundle)
    }

    static func sameBundle(_ a: URL, _ b: URL) -> Bool {
        CrossOverSource.same(a, b)
    }
}
