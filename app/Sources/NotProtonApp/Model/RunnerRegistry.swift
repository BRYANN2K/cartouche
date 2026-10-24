
import Foundation

struct RunnerRegistry: Sendable {

    var runners: [Runner] = []

    var installs: [CrossOverInstall] = []
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
        free: FreeRunnerScan? = nil
    ) -> RunnerRegistry {
        let installs = CrossOverSource.discover(
            roots: roots, manual: manual, pins: pins, excluding: [runners, SupportPaths.Steam.compatTools])
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
}

extension RunnerRegistry {

    static func state(runners: URL = SupportPaths.runners) -> RunnerState {
        RunnerStore.state(runners: runners)
    }

    // The compatibility tools Steam was offered, as the tool list records them.
    static func compatibilityTools() -> [InstalledTool] { CompatToolList.installed() }

    static func installedBuilds(in runners: URL = SupportPaths.runners) -> [RunnerBuild] {
        RunnerStore.installedBuilds(in: runners)
    }

    static func clonedBuilds(in runners: URL = SupportPaths.runners) -> [String] {
        RunnerStore.clonedBuilds(in: runners)
    }

    static func cloneSize(forBuild build: String, runners: URL = SupportPaths.runners) -> Int64 {
        RunnerStore.cloneSize(forBuild: build, runners: runners)
    }

    static func tools(runners: URL = SupportPaths.runners, file: URL = SupportPaths.toolList) -> [InstalledTool] {
        CompatToolList.installed(runners: runners, file: file)
    }

    static func backendTools(runners: URL = SupportPaths.runners, file: URL = SupportPaths.toolList) -> [BackendTool] {
        CompatToolList.backendTools(for: CompatToolList.installed(runners: runners, file: file), runners: runners)
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

    static func sameBundle(_ a: URL, _ b: URL) -> Bool {
        CrossOverSource.same(a, b)
    }
}
