import Foundation
import Testing

@testable import NotProtonApp

// The Runners screen's model on scratch folders: no real CrossOver, Steam,
// runners folder or network is read.
@Suite("Runners model")
@MainActor
final class RunnersModelTests {

    let work: URL
    let runners: URL
    // Fixture suites delete their folders when released
    var kept: [AnyObject] = []

    init() throws {
        work = try scratchDirectory("runners-model")
        runners = work.appending(path: "runners")
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    func model(builds: [RunnerManifest.Build], toolkits: @escaping @Sendable () -> [PortingToolkitInstall] = { [] }) -> RunnersModel {
        let bridge = work.appending(path: "bridge")
        return RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds), toolkits: toolkits()) },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: bridge, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json")
        )
    }

    // Reuses the install suite's fixture archive
    func fixture() throws -> (RunnerManifest.Build, WineRunnerInstallerTests) {
        let installTests = try WineRunnerInstallerTests()
        kept.append(installTests)
        let archive = try installTests.archive()
        let pinned = try installTests.build(for: archive)
        return (pinned, installTests)
    }

    @Test("Download on Wine CrossOver 26.3 installs it and the row reads Ready")
    func download() async throws {
        let (build, _) = try fixture()
        let model = model(builds: [build])
        await model.refresh()
        let before = try #require(model.rows.first { $0.id == build.id })
        #expect(before.title == "Wine CrossOver 26.3")
        #expect(before.detail == "Built by Cartouche from CodeWeavers’ open-source code")
        #expect(before.status == "Not installed")
        #expect(before.action == .download)

        await model.perform(.download, on: build.id)

        let after = try #require(model.rows.first { $0.id == build.id })
        #expect(after.status == "Ready")
        #expect(after.state == .ready)
        #expect(after.action == .none)
        #expect(model.message == nil)
        #expect(WineRunnerInstaller.isInstalled(build.id, runners: runners))
    }

    @Test("A damaged download leaves the runner not installed and tells the user")
    func damagedDownload() async throws {
        let (build, _) = try fixture()
        let wrong = RunnerManifest.Build(
            id: build.id, kind: build.kind, origin: build.origin, name: build.name, version: build.version,
            displayVersion: build.displayVersion, url: build.url, size: build.size,
            sha256: String(repeating: "0", count: 64), root: build.root, loader: build.loader, flavors: build.flavors)
        let model = model(builds: [wrong])
        await model.refresh()
        await model.download(wrong.id)

        #expect(model.message == "The download was damaged. Try again.")
        let row = try #require(model.rows.first { $0.id == wrong.id })
        #expect(row.status == "Not installed")
        #expect(row.action == .download)
        #expect(!WineRunnerInstaller.isInstalled(wrong.id, runners: runners))
    }

    @Test("Without a toolkit the row reads Not found with How to Get It, and D3DMetal is not offered")
    func toolkitAbsent() async throws {
        let model = model(builds: [])
        await model.refresh()
        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.title == "Game Porting Toolkit")
        #expect(row.status == "Not found")
        #expect(row.link == RunnersModel.Row.Link(
            title: "How to Get It", url: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!))
        #expect(model.d3dMetal == nil)
    }

    @Test("A toolkit found on the Mac is copied on refresh and reads Ready with its version, offering D3DMetal")
    func toolkitFound() async throws {
        let fixtures = try PortingToolkitTests()
        kept.append(fixtures)
        let apps = fixtures.work.appending(path: "Applications")
        let app = apps.appending(path: "Game Porting Toolkit.app")
        try fixtures.toolkit(at: app.appending(path: "Contents/Resources/wine/lib"), version: "3.0")
        let search = fixtures.search(applications: [apps])
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })

        await model.refresh()

        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.title == "Game Porting Toolkit 3.0")
        #expect(row.status == "Ready")
        #expect(row.detail == "Found in \(PortingToolkitTests.path(apps))")
        #expect(model.rows.filter { $0.kind == .portingToolkit }.count == 1)
        #expect(FileManager.default.fileExists(atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
        guard case .portingToolkit(version: "3.0", _) = model.d3dMetal else {
            Issue.record("D3DMetal not offered from the copy: \(String(describing: model.d3dMetal))")
            return
        }
    }

    @Test("A newer manifest is fetched at most once a day")
    func dailyManifest() async throws {
        let suite = "runners-model-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = work.appending(path: "runners.json")
        let shipped = try RunnerManifest.bundled()
        let newer = try RunnerManifestTests.manifest([RunnerManifestTests.entry()], revision: shipped.revision + 1)
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let model = RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest.current(cache: cache)) },
            registry: { RunnerRegistry.refresh(runners: $0, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: URL(string: "https://github.com/BRYANN2K/NotProton/releases/download/compat-data/runners.json")!,
            manifestCache: cache, fetch: { _ in count.n += 1; return (newer, 200) }, defaults: defaults
        )
        let now = Date()
        await model.refreshManifestIfDue(now: now)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(60 * 60))
        #expect(count.n == 1)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(25 * 60 * 60))
        #expect(count.n == 2)
        await model.refresh()
        #expect(model.rows.contains { $0.title == "Wine CrossOver 26.3" })
    }
}
