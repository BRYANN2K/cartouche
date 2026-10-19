import Foundation
import Testing

@testable import NotProtonApp

// A CrossOver.app built from scratch, with a build pinned to its own hashes, so the real
// discovery, clone, patch and verify code can run without CodeWeavers' bytes.
struct CrossOverFixture: ~Copyable {

    static let bundleVersion = "90.0.0.1"
    static let releaseVersion = "20990101"
    static let arches: [WineArch] = [.x86_64Windows, .i386Windows]

    let work: URL
    let applications: URL
    let runners: URL
    let bridge: URL
    let bundle: URL
    let build: RunnerBuild

    var clone: URL { SupportPaths.clonedRoot(forBuild: build.id, runners: runners) }
    var toolList: URL { work.appending(path: "tools") }

    static func clean(_ arch: WineArch) -> Data { Data("clean \(arch.rawValue) ntdll".utf8) }
    static func patched(_ arch: WineArch) -> Data { Data("patched \(arch.rawValue) ntdll".utf8) }

    init(pinned: Bool = true) throws {
        // Every throw happens before a stored property is set, as a noncopyable type requires.
        let fm = FileManager.default
        let work = try scratchDirectory("crossover-runner")
        let applications = work.appending(path: "Applications")
        let bridge = work.appending(path: "bridge")
        let bundle = applications.appending(path: "CrossOver.app")

        let wine = SupportPaths.crossOverRoot(inBundle: bundle).appending(path: "lib/wine")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleVersion": Self.bundleVersion, "CFBundleShortVersionString": Self.releaseVersion,
            ],
            format: .xml, options: 0
        )
        try fm.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        try plist.write(to: bundle.appending(path: "Contents/Info.plist"))

        // A real Mach-O signed with the dyld entitlement the patch step grants.
        let loader = wine.appending(path: "x86_64-unix/wine")
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: loader)
        let entitlements = work.appending(path: "entitlements.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.cs.allow-dyld-environment-variables": true],
            format: .xml, options: 0
        ).write(to: entitlements)
        let signed = try Shell.run("/usr/bin/codesign", [
            "-f", "-s", "-", "--entitlements", entitlements.path(percentEncoded: false),
            loader.path(percentEncoded: false),
        ])
        try #require(signed.status == 0)

        for arch in Self.arches {
            let ntdll = wine.appending(path: "\(arch.rawValue)/ntdll.dll")
            try fm.createDirectory(at: ntdll.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.clean(arch).write(to: ntdll)
        }

        for builtin in [("i386-windows", "lsteamclient.dll"), ("x86_64-windows", "lsteamclient.dll"),
                        ("x86_64-unix", "lsteamclient.so")] {
            let staged = bridge.appending(path: "\(builtin.0)/\(builtin.1)")
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bridge \(builtin.0) \(builtin.1)".utf8).write(to: staged)
        }

        var clean: [WineArch: String] = [:]
        var patched: [WineArch: String] = [:]
        for arch in Self.arches {
            clean[arch] = Digest.sha256(of: Self.clean(arch))
            patched[arch] = Digest.sha256(of: Self.patched(arch))
        }
        let loaderHash = try #require(Digest.sha256IfPresent(loader))
        self.work = work
        self.applications = applications
        self.runners = work.appending(path: "runners")
        self.bridge = bridge
        self.bundle = bundle
        self.build = RunnerBuild(
            bundleVersion: Self.bundleVersion, releaseVersion: Self.releaseVersion, flavor: "fex",
            loaderSHA256: pinned ? loaderHash : String(repeating: "0", count: 64),
            cleanNtdll: clean, patchedNtdll: patched,
            tools: [
                CompatTool(name: "\(SupportPaths.toolPrefix)-fixture-fex", flavor: .fex, display: "Fixture FEX"),
                CompatTool(name: "\(SupportPaths.toolPrefix)-fixture-rosetta", flavor: .rosetta, display: "Fixture Rosetta"),
            ]
        )
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    var pins: [RunnerBuild] { [build] }

    func refresh(pins: [RunnerBuild]? = nil) -> RunnerRegistry {
        RunnerRegistry.refresh(
            runners: runners, bridge: bridge, roots: [applications], manual: [], pins: pins ?? self.pins,
            fexAvailable: true
        )
    }

    // What Set Up and Repair run: clone, then prepare. NtdllPatcher.stage needs CrossOver's
    // real ntdll to find its hook sites, so the staged copies are written here instead.
    func setUp(_ install: CrossOverInstall) throws -> RunnerSetup.Outcome {
        let work = self.work
        let build = try RunnerInstaller.clone(from: install, runners: runners)
        return try RunnerSetup.prepare(
            build, runners: runners, bridge: bridge, toolList: toolList,
            compatTools: work.appending(path: "compatibilitytools.d"),
            runScript: {
                let script = work.appending(path: "payload-run")
                try Data("#!/bin/sh\n".utf8).write(to: script)
                return script
            },
            license: { _ in CrossOverLicense.Status(licensed: true, detail: "", diagnostic: "test") },
            stage: { build, _, bridge in
                for arch in Self.arches {
                    try atomicReplace(
                        NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge),
                        with: Self.patched(arch), step: "test")
                }
                return Self.arches
            }
        )
    }
}

@Suite("CrossOver on the runner model")
struct CrossOverRunnerTests {

    @Test("A supported CrossOver in Applications is one CrossOver runner, ready once set up")
    func crossOverAppearsAsARunner() throws {
        let fixture = try CrossOverFixture()

        var registry = fixture.refresh()
        let found = try #require(registry.runners.first)
        #expect(registry.runners.count == 1)
        #expect(found.kind == .crossOver)
        #expect(found.id == "\(CrossOverFixture.bundleVersion)-fex")
        #expect(found.version == CrossOverFixture.bundleVersion)
        #expect(found.flavors == [.rosetta, .fex])
        #expect(found.state == .available)
        #expect(found.source.map { CrossOverSource.same($0, fixture.bundle) } == true)
        #expect(!found.isOffered)

        let started = registry.apply(.install, to: found.id)
        #expect(started)
        #expect(registry.runner(id: found.id)?.state == .installing(from: .available))

        let install = try #require(registry.installs.first)
        let outcome = try fixture.setUp(install)
        #expect(outcome.build.id == found.id)
        #expect(outcome.installed.ntdll == CrossOverFixture.arches)

        let problems = RunnerRegistry.verify(found, runners: fixture.runners, bridge: fixture.bridge)
        #expect(problems.isEmpty)
        registry.apply(.verified(problems: problems), to: found.id)
        #expect(registry.runner(id: found.id)?.state == .ready)

        let refreshed = fixture.refresh()
        let ready = try #require(refreshed.runner(id: found.id))
        #expect(refreshed.runners.count == 1)
        #expect(ready.state == .ready)
        #expect(ready.isOffered)
        #expect(ready.flavors == [.rosetta, .fex])
        #expect(refreshed.state == .ready(builds: [found.id]))
        for arch in CrossOverFixture.arches {
            let live = fixture.clone.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
            #expect(Digest.sha256IfPresent(live) == fixture.build.patchedNtdll[arch])
        }
    }

    @Test("On macOS 15 the same runner serves Rosetta only")
    func sequoiaFlavors() throws {
        let fixture = try CrossOverFixture()
        let registry = RunnerRegistry.refresh(
            runners: fixture.runners, bridge: fixture.bridge, roots: [fixture.applications], manual: [],
            pins: fixture.pins, fexAvailable: false
        )
        #expect(registry.runners.map(\.flavors) == [[.rosetta]])
    }

    @Test("A CrossOver whose hashes are not pinned is unsupported with its reason, and offered to nothing",
          arguments: [false, true])
    func unpinnedBuildIsReported(realPins: Bool) throws {
        // Unknown to the fixture's own pin, and to the shipped allow list.
        let fixture = try CrossOverFixture(pinned: false)
        let registry = fixture.refresh(pins: realPins ? SupportedRunners.all : nil)

        let runner = try #require(registry.runners.first)
        let reason = "Version \(CrossOverFixture.releaseVersion) not supported (supported: \(SupportedRunners.versionList))"
        #expect(registry.runners.count == 1)
        #expect(runner.kind == .crossOver)
        #expect(runner.state == .unsupported(reason: reason))
        #expect(runner.reason == reason)
        #expect(runner.build == nil)
        #expect(runner.flavors.isEmpty)
        #expect(registry.offered.isEmpty)

        var attempt = registry
        let started = attempt.apply(.install, to: runner.id)
        #expect(!started)

        // Setting it up is refused before anything is copied.
        let install = try #require(registry.installs.first)
        #expect(throws: StepFailure.self) { try fixture.setUp(install) }
        #expect(!FileManager.default.fileExists(atPath: fixture.runners.path(percentEncoded: false)))

        // Steam's list and the games' tool picker both read the list file.
        try CompatToolList.sync(
            runners: fixture.runners, bridge: fixture.bridge, file: fixture.toolList,
            compatTools: fixture.work.appending(path: "compatibilitytools.d"), fexAvailable: true)
        #expect(RunnerRegistry.tools(runners: fixture.runners, file: fixture.toolList).isEmpty)
        #expect(RunnerRegistry.tools(for: registry.offered.compactMap(\.build)).isEmpty)
    }

    @Test("One flipped byte in a set-up runner's ntdll makes it damaged, and Repair restores the pinned hash")
    func flippedByteIsCaught() throws {
        let fixture = try CrossOverFixture()
        let install = try #require(fixture.refresh().installs.first)
        _ = try fixture.setUp(install)
        #expect(fixture.refresh().runners.map(\.state) == [.ready])

        let live = fixture.clone.appending(path: "lib/wine/x86_64-windows/ntdll.dll")
        var bytes = try Data(contentsOf: live)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: live)

        let damaged = fixture.refresh()
        let runner = try #require(damaged.runners.first)
        let problem = "x86_64-windows/ntdll.dll is not the patched copy"
        #expect(runner.state == .damaged(files: [problem]))
        #expect(runner.reason == problem)
        #expect(damaged.state == .unpatched(builds: [runner.id], problems: ["\(runner.id): \(problem)"]))

        // The Status pane offers Repair on that row, which sets the runner up again from its copy.
        let row = try #require(CrossOverRow.rows(
            installs: damaged.installs, licenses: [:], installed: damaged.installed,
            damaged: damaged.damaged, orphaned: damaged.orphaned, unpatched: damaged.state.builds
        ).first)
        #expect(row.copy == .unpatched)
        #expect(row.canSetUp)

        let repaired = try fixture.setUp(install)
        #expect(repaired.installed.ntdll == [.x86_64Windows])
        #expect(Digest.sha256IfPresent(live) == fixture.build.patchedNtdll[.x86_64Windows])
        #expect(fixture.refresh().runners.map(\.state) == [.ready])
    }
}
