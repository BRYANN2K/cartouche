import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner registry")
struct RunnerRegistryTests {

    private static let fex = SupportedRunners.build(id: "27.0.0.40921-fex")!
    private static let x86 = SupportedRunners.build(id: "27.0.0.40921")!
    private static let release = SupportedRunners.build(id: "26.3.0.39832")!

    private func install(
        _ name: String, _ support: CrossOverSupport, isManual: Bool = false
    ) -> CrossOverInstall {
        CrossOverInstall(
            bundle: URL(filePath: "/Applications/\(name).app"), releaseVersion: "20260821",
            support: support, isManual: isManual
        )
    }

    // The runner model files are where CrossOver is handled. Everything else is a feature.
    private static let runnerModel: Set<String> = [
        "CrossOverSource.swift", "CrossOverLicense.swift", "RunnerStore.swift", "RunnerInstaller.swift",
        "RunnerPatcher.swift", "RunnerSetup.swift", "SupportedRunner.swift", "NtdllPatcher.swift",
        "Runner.swift", "RunnerRegistry.swift",
    ]

    @Test("Features read runners only from the registry")
    func featuresReadTheRegistry() throws {
        let direct = ["CrossOverSource", "RunnerStore", "SupportedRunners", "CompatToolList.installed"]
        var offenders: [String] = []
        for file in try IdentityTests.appSources() where !Self.runnerModel.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in direct where text.contains(name) {
                offenders.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(offenders.isEmpty)
    }

    @Test("A supported CrossOver that was set up is one ready runner with its build and flavors")
    func crossOverIsARunner() throws {
        let found = install("CrossOver Preview", .supported(Self.fex))
        let runners = CrossOverSource.runners(
            installs: [found], installed: [Self.fex], damaged: [], orphaned: [], problems: [:], fexAvailable: true
        )

        let runner = try #require(runners.first)
        #expect(runners.count == 1)
        #expect(runner.kind == .crossOver)
        #expect(runner.id == Self.fex.id)
        #expect(runner.version == "27.0.0.40921")
        #expect(runner.flavors == [.rosetta, .fex])
        #expect(runner.state == .ready)
        #expect(runner.source == found.bundle)
        #expect(runner.isOffered)

        let sequoia = CrossOverSource.runners(
            installs: [found], installed: [Self.fex], damaged: [], orphaned: [], problems: [:], fexAvailable: false
        )
        #expect(sequoia.first?.flavors == [.rosetta])
    }

    @Test("A supported CrossOver not set up yet is available and not offered")
    func notSetUpIsAvailable() {
        let runners = CrossOverSource.runners(
            installs: [install("CrossOver", .supported(Self.release))],
            installed: [], damaged: [], orphaned: [], problems: [:]
        )
        #expect(runners.map(\.state) == [.available])
        #expect(runners.filter(\.isOffered).isEmpty)
    }

    @Test("An unpinned CrossOver is unsupported with its reason and never offered")
    func unpinnedIsUnsupported() {
        let found = install("CrossOver", .unsupportedBuild("30.0"))
        let registry = RunnerRegistry(
            runners: CrossOverSource.runners(
                installs: [found, install("CrossOver Preview", .supported(Self.x86))],
                installed: [Self.x86], damaged: [], orphaned: [], problems: [:]
            ),
            installed: [Self.x86]
        )

        let runner = registry.runner(id: found.id)
        #expect(runner?.state == .unsupported(
            reason: "Version 30.0 not supported (supported: \(SupportedRunners.versionList))"))
        #expect(runner?.reason?.hasPrefix("Version 30.0 not supported") == true)
        #expect(runner?.build == nil)
        #expect(registry.offered.map(\.id) == [Self.x86.id])
        #expect(RunnerRegistry.tools(for: registry.offered.compactMap(\.build)).allSatisfy { $0.build == Self.x86.id })
    }

    @Test("Unreadable copies are left out, as the Status pane leaves them out")
    func unreadableIsSkipped() {
        let runners = CrossOverSource.runners(
            installs: [install("CrossOver", .unreadable)], installed: [], damaged: [], orphaned: [], problems: [:]
        )
        #expect(runners.isEmpty)
    }

    @Test("A clone verify finds wrong is damaged, naming the files")
    func unpatchedIsDamaged() {
        let problems = ["x86_64-windows/ntdll.dll is not the patched copy", "i386-windows/lsteamclient.dll is missing"]
        let runners = CrossOverSource.runners(
            installs: [], installed: [Self.release], damaged: [], orphaned: [], problems: [Self.release.id: problems]
        )
        #expect(runners.map(\.state) == [.damaged(files: problems)])
        #expect(runners.first?.reason == problems.joined(separator: "\n"))
        #expect(runners.first?.isOffered == true)
    }

    @Test("A clone with no lib/wine is damaged and not offered")
    func incompleteIsDamaged() {
        let runners = CrossOverSource.runners(
            installs: [], installed: [], damaged: [Self.release.id], orphaned: [], problems: [:]
        )
        #expect(runners.map(\.state) == [.damaged(files: ["The clone has no Wine loader at lib/wine."])])
        #expect(runners.first?.isOffered == false)
    }

    @Test("A clone no longer pinned is unsupported")
    func orphanIsUnsupported() {
        let runners = CrossOverSource.runners(
            installs: [], installed: [], damaged: [], orphaned: ["1.0.0.1"], problems: [:]
        )
        #expect(runners.map(\.state) == [.unsupported(reason: "Build 1.0.0.1, not supported")])
        #expect(runners.first?.isOffered == false)
    }

    @Test("Runners follow the Status pane's order, one per build")
    func orderAndDedup() {
        let runners = CrossOverSource.runners(
            installs: [
                install("CrossOver Preview", .supported(Self.x86)),
                install("CrossOver", .supported(Self.x86)),
                install("CrossOver Old", .unsupportedBuild("30.0")),
            ],
            installed: [Self.release, Self.x86], damaged: [Self.fex.id], orphaned: ["1.0.0.1"], problems: [:]
        )
        #expect(runners.map(\.id) == [
            Self.x86.id, "/Applications/CrossOver Old.app", Self.release.id, Self.fex.id, "1.0.0.1",
        ])
        #expect(runners.first?.source?.lastPathComponent == "CrossOver Preview.app")
    }

    @Test("A refresh agrees with the clone checks and with the list Steam reads")
    func refreshMatchesTheStore() throws {
        let work = try scratchDirectory("registry")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let bridge = work.appending(path: "bridge")
        for build in [Self.release, Self.fex] {
            try FileManager.default.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build.id, runners: runners).appending(path: "lib/wine"),
                withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.x86.id, runners: runners), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runners.appending(path: "crossover-1.0.0.1/CrossOver/lib/wine"), withIntermediateDirectories: true)

        let registry = RunnerRegistry.refresh(runners: runners, bridge: bridge, roots: [], manual: [], fexAvailable: true)

        #expect(registry.state == RunnerStore.state(runners: runners, verify: {
            RunnerPatcher.verify(build: $0, root: $1, bridge: bridge)
        }))
        #expect(registry.installed == RunnerStore.installedBuilds(in: runners))
        #expect(registry.damaged == [Self.x86.id])
        #expect(registry.orphaned == ["1.0.0.1"])
        #expect(Set(registry.offered.map(\.id)) == [Self.release.id, Self.fex.id])

        let file = work.appending(path: "tools")
        try CompatToolList.sync(
            runners: runners, bridge: bridge, file: file,
            compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true)
        let listed = CompatToolList.installed(runners: runners, file: file)
        #expect(SupportedRunners.tools(for: registry.offered.compactMap(\.build), fexAvailable: true) == listed)
    }

    @Test("Marking a runner installing reaches only that runner")
    func applyByID() {
        var registry = RunnerRegistry(runners: CrossOverSource.runners(
            installs: [install("CrossOver", .supported(Self.release)), install("CrossOver Old", .unsupportedBuild("30.0"))],
            installed: [], damaged: [], orphaned: [], problems: [:]
        ))
        let started = registry.apply(.install, to: Self.release.id)
        let refused = registry.apply(.install, to: "/Applications/CrossOver Old.app")
        let missing = registry.apply(.install, to: "nothing")
        #expect(started)
        #expect(!refused)
        #expect(!missing)
        #expect(registry.runners.map(\.state) == [
            .installing(from: .available), .unsupported(reason: "Version 30.0 not supported (supported: \(SupportedRunners.versionList))"),
        ])
    }
}
