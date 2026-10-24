import Foundation

enum RunnerSetup {

    enum Phase: Sendable {
        case cloning
        case staging
        case patching
        case finished

        var label: String {
            switch self {
            case .cloning: String(localized: "Copying CrossOver")
            case .staging: String(localized: "Patching")
            case .patching: String(localized: "Installing compatibility tool")
            case .finished: String(localized: "Done")
            }
        }
    }

    struct Outcome: Sendable {
        let build: RunnerBuild
        let staged: [WineArch]
        let installed: RunnerPatcher.Outcome
        var toolsChanged = false

        var stagedNothing: Bool { staged.isEmpty && installed.wroteNothing && !toolsChanged }
    }

    static func run(
        from install: CrossOverInstall,
        replacingExisting: Bool = false,
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        try CrossOverLicense.requireValid(for: install)

        report(.cloning)
        let build = try RunnerInstaller.clone(from: install, replacingExisting: replacingExisting)
        return try prepare(build, report: report)
    }

    static let prepareStep = String(localized: "Set up compatibility tool")

    static func prepare(
        _ build: RunnerBuild,
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        toolList: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        license: (URL) -> CrossOverLicense.Status = { CrossOverLicense.check(crossOverRoot: $0) },
        verify: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        stage: (RunnerBuild, URL, URL) throws -> [WineArch] = {
            try NtdllPatcher.stage(build: $0, runnerRoot: $1, bridge: $2)
        },
        patch: (RunnerBuild, URL, URL) throws -> RunnerPatcher.Outcome = {
            try RunnerPatcher.install(build: $0, root: $1, bridge: $2)
        },
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        guard RunnerInstaller.hasClone(forBuild: build.id, runners: runners) else {
            throw StepFailure(
                step: prepareStep, detail: String(localized: "Build \(build.displayVersion) has not been set up.")
            )
        }

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let status = license(root)
        guard status.licensed else {
            throw StepFailure(step: String(localized: "Verify CrossOver license"), detail: status.detail)
        }

        try verify(build, root)

        report(.staging)
        let staged = try stage(build, root, bridge)

        report(.patching)
        var outcome = Outcome(build: build, staged: staged, installed: try patch(build, root, bridge))
        outcome.toolsChanged = try CompatToolList.sync(
            runners: runners, bridge: bridge, file: toolList, compatTools: compatTools
        )
        try deployRunScripts(runners: runners, toolList: toolList, compatTools: compatTools,
                             runScript: runScript)

        report(.finished)
        return outcome
    }

    // Prepare the downloaded engine before registering its Steam tools.
    @discardableResult
    static func prepareWine(
        _ build: RunnerManifest.Build,
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        toolList: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        patch: (URL, URL) throws -> RunnerPatcher.Outcome = {
            try RunnerPatcher.installWine(root: $0, bridge: $1)
        },
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> (installed: RunnerPatcher.Outcome, toolsChanged: Bool) {
        guard let root = WineRunnerInstaller.installedFolder(for: build.id, runners: runners) else {
            throw StepFailure(
                step: prepareStep,
                detail: String(localized: "Build \(build.title) has not been set up."))
        }

        report(.staging)
        if !FileManager.default.fileExists(atPath: bridge.appending(path: "x86_64-windows/lsteamclient.dll").path) {
            _ = try BridgePayload.stage(located: BridgePayload.locate(), bridge: bridge)
        }
        let installed = try patch(root, bridge)
        try WineRunnerInstaller.recordPreparedLoader(build.id, runners: runners)

        report(.patching)
        let changed = try CompatToolList.sync(
            runners: runners, bridge: bridge, file: toolList, compatTools: compatTools
        )
        try deployRunScripts(runners: runners, toolList: toolList, compatTools: compatTools,
                             runScript: runScript)

        report(.finished)
        return (installed, changed)
    }

    // The dylib rewrites each tool's run script on launch; deploying it now lets
    // Steam pick the tool up before Cartouche runs again.
    private static func deployRunScripts(
        runners: URL, toolList: URL, compatTools: URL, runScript: () throws -> URL
    ) throws {
        for tool in CompatToolList.installed(runners: runners, file: toolList) {
            let run = compatTools.appending(path: "\(tool.name)/run")
            if FileManager.default.fileExists(atPath: run.path(percentEncoded: false)) { continue }
            try SteamInstaller.installIfChanged(DeploymentContent.File(
                source: try runScript(), destination: run, name: "\(tool.name)/run", executable: true))
        }
    }
}
