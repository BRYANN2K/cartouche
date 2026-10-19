import CryptoKit
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
    let defaultsName: String
    let defaults: UserDefaults
    // Fixture suites delete their folders when released
    var kept: [AnyObject] = []

    init() throws {
        work = try scratchDirectory("runners-model")
        runners = work.appending(path: "runners")
        defaultsName = "runners-model-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
    }

    deinit {
        try? FileManager.default.removeItem(at: work)
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
    }

    func model(builds: [RunnerManifest.Build], toolkits: @escaping @Sendable () -> [PortingToolkitInstall] = { [] }) -> RunnersModel {
        let bridge = work.appending(path: "bridge")
        return RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds), toolkits: toolkits()) },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: bridge, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json"),
            defaults: defaults
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

    // A scratch app folder holding a fixture toolkit of the given version
    func toolkitApp(_ version: String = "3.0") throws -> (PortingToolkitTests, URL) {
        let fixtures = try PortingToolkitTests()
        kept.append(fixtures)
        let apps = fixtures.work.appending(path: "Applications")
        try fixtures.toolkit(
            at: apps.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib"), version: version)
        return (fixtures, apps)
    }

    @Test("A toolkit found on the Mac asks once with its size; Copy installs it and reads Ready")
    func toolkitCopy() async throws {
        let (fixtures, apps) = try toolkitApp()
        let search = fixtures.search(applications: [apps])
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })

        await model.refresh()

        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.title == "Game Porting Toolkit 3.0")
        #expect(row.status == "Not installed")
        #expect(row.action == .setUp)
        let question = try #require(model.toolkitQuestion)
        #expect(question.install.version == "3.0")
        #expect(question.copySize > 0)

        await model.answerToolkit(.copy)

        let after = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(after.status == "Ready")
        #expect(after.detail == "Found in \(PortingToolkitTests.path(apps))")
        #expect(model.toolkitQuestion == nil)
        #expect(FileManager.default.fileExists(atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
        guard case .portingToolkit(version: "3.0", _) = model.d3dMetal else {
            Issue.record("D3DMetal not offered from the copy: \(String(describing: model.d3dMetal))")
            return
        }
    }

    @Test("Use in Place records the folder, keeps no copy, and reads the framework there")
    func toolkitInPlace() async throws {
        let (fixtures, apps) = try toolkitApp()
        let lib = apps.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let search = fixtures.search(applications: [apps])
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()

        await model.answerToolkit(.inPlace)

        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.status == "Ready")
        #expect(PortingToolkitSource.receipt(version: "3.0", runners: runners)?.inPlace
            == PortingToolkitTests.path(lib))
        #expect(!FileManager.default.fileExists(
            atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
                .appending(path: "lib").path(percentEncoded: false)))
        guard case .portingToolkit(version: "3.0", let framework) = model.d3dMetal else {
            Issue.record("D3DMetal not offered in place: \(String(describing: model.d3dMetal))")
            return
        }
        #expect(PortingToolkitTests.path(framework) == PortingToolkitTests.path(
            lib.appending(path: "external/D3DMetal.framework")))

        // The recorded folder goes away: the row says so and offers to copy anew
        try FileManager.default.removeItem(at: apps.appending(path: "Game Porting Toolkit.app"))
        await model.refresh()
        let missing = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(missing.status == "Damaged")
        #expect(missing.detail.contains("is gone"))
        #expect(missing.action == .repair)
        #expect(model.d3dMetal == nil)

        // Repair copies the toolkit from a folder the user picks
        let (other, otherApps) = try toolkitApp()
        _ = other
        model.chooseToolkitFolder = { otherApps.appending(path: "Game Porting Toolkit.app") }
        await model.perform(.repair, on: "gptk-3.0")

        let repaired = try #require(model.rows.first { $0.id == "gptk-3.0" })
        #expect(repaired.status == "Ready")
        #expect(FileManager.default.fileExists(atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
    }

    @Test("A dismissed question is not asked again, and Set Up asks it once more")
    func toolkitAskedOnce() async throws {
        let (fixtures, apps) = try toolkitApp()
        let search = fixtures.search(applications: [apps])
        let model = model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()
        #expect(model.toolkitQuestion != nil)

        model.dismissToolkitQuestion()
        await model.refresh()
        #expect(model.toolkitQuestion == nil)
        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.action == .setUp)

        await model.perform(.setUp, on: "gptk-3.0")
        #expect(model.toolkitQuestion != nil)
        await model.answerToolkit(.inPlace)
        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Ready")
    }

    @Test("A newer manifest is fetched at most once a day, and not at all when daily checks are off")
    func dailyManifest() async throws {
        let cache = work.appending(path: "runners.json")
        let shipped = try RunnerManifest.bundled()
        let newer = try RunnerManifestTests.manifest([RunnerManifestTests.entry()], revision: shipped.revision + 1)
        // A throwaway key signs the published manifest; the .sig fetch counts too
        let (key, feed) = try RunnerManifestTests.feed(manifest: newer, key: Curve25519.Signing.PrivateKey())
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let model = RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest.current(cache: cache)) },
            registry: { RunnerRegistry.refresh(runners: $0, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: URL(string: "https://github.com/BRYANN2K/cartouche/releases/download/compat-data/runners.json")!,
            manifestCache: cache, manifestKey: key,
            fetch: { url in count.n += 1; return try await feed(url) }, defaults: defaults
        )
        let now = Date()
        await model.refreshManifestIfDue(now: now)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(60 * 60))
        #expect(count.n == 2)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(25 * 60 * 60))
        #expect(count.n == 4)
        await model.refresh()
        #expect(model.rows.contains { $0.title == "Wine CrossOver 26.3" })

        // The daily switch pauses the manifest fetch too
        defaults.set(false, forKey: DailyChecks.key)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(50 * 60 * 60))
        #expect(count.n == 4)
        defaults.removeObject(forKey: DailyChecks.key)
    }
}
