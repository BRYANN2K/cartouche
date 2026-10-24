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

    // The scratch volumes root every discover() is pointed at: never the real one
    func volumes() -> URL { work.appending(path: "Volumes-\(UUID().uuidString)") }

    func offered(_ model: RunnersModel) -> Set<String> {
        BackendAvailability.current(
            registry: model.registry, runners: runners, backends: work.appending(path: "backends"),
            manifest: RunnerManifest(format: 1, revision: 1, builds: [])).d3dMetalRunners
    }

    func model(builds: [RunnerManifest.Build], toolkits: @escaping @Sendable () -> [PortingToolkitInstall] = { [] },
               isRunning: @escaping @Sendable (URL) -> Bool = { _ in false },
               onSync: @escaping @Sendable () -> Void = {}) throws -> RunnersModel {
        let bridge = work.appending(path: "bridge")
        for (arch, name) in [("i386-windows", "lsteamclient.dll"), ("x86_64-windows", "lsteamclient.dll"),
                             ("x86_64-unix", "lsteamclient.so")] {
            let file = bridge.appending(path: "\(arch)/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bridge".utf8).write(to: file)
        }
        let run = work.appending(path: "run")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: run)
        return RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            prepareWine: { build, runners in
                _ = try RunnerSetup.prepareWine(
                    build, runners: runners, bridge: bridge,
                    toolList: bridge.deletingLastPathComponent().appending(path: "tools"),
                    compatTools: bridge.deletingLastPathComponent().appending(path: "compatibilitytools.d"),
                    runScript: { run })
            },
            syncTools: { runners in
                onSync()
                _ = try CompatToolList.sync(
                    runners: runners, bridge: bridge,
                    file: bridge.deletingLastPathComponent().appending(path: "tools"),
                    compatTools: bridge.deletingLastPathComponent().appending(path: "compatibilitytools.d"))
            },
            isRunning: isRunning,
            scan: { FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds), toolkits: toolkits()) },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: bridge, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json"),
            defaults: defaults
        )
    }

    @Test("Downloading Wine on a fresh Mac stages its bridge without a Steam repair")
    func firstDownloadStagesBridge() async throws {
        let build = try await fixture()
        let model = try model(builds: [build])
        await model.refresh()
        let bridge = work.appending(path: "bridge")
        try FileManager.default.removeItem(at: bridge)
        let prepared = await model.download(build.id)
        #expect(prepared)
        #expect(model.message == nil)
        let engine = WineRunnerInstaller.dir(for: build.id, runners: runners)
        for path in ["i386-windows/lsteamclient.dll", "x86_64-windows/lsteamclient.dll", "x86_64-unix/lsteamclient.so"] {
            #expect(Digest.sha256IfPresent(engine.appending(path: "lib/wine/\(path)")) == Digest.sha256IfPresent(bridge.appending(path: path)))
            #expect(FileManager.default.fileExists(atPath: bridge.appending(path: path).path))
        }
        #expect(!FileManager.default.fileExists(atPath: SupportPaths.clonedRoot(forBuild: build.id, runners: runners).path))
    }

    // A fixture archive and its manifest entry, laid out in this suite's scratch folder.
    // archive() waits on tar, so it builds off this suite's main actor.
    func fixture() async throws -> RunnerManifest.Build {
        let archive = try await offMain { try WineRunnerInstallerTests.archive(id: "wine-crossover-26.3.0-1", in: self.work) }
        return try WineRunnerInstallerTests.build(id: "wine-crossover-26.3.0-1", for: archive)
    }

    @Test("Download on Cartouche Wine 26.3.0-1 installs it and the row reads Ready")
    func download() async throws {
        let build = try await fixture()
        let model = try model(builds: [build])
        await model.refresh()
        let before = try #require(model.rows.first { $0.id == build.id })
        #expect(before.title == "Cartouche Wine 26.3.0-1")
        #expect(before.detail == "Cartouche Wine · D3DMetal, DXMT")
        #expect(before.status == "Not installed")
        #expect(before.action == .download)

        var refreshed = 0
        model.didChange = { refreshed += 1 }
        await model.perform(.download, on: build.id)
        #expect(refreshed == 1)

        let after = try #require(model.rows.first { $0.id == build.id })
        #expect(after.status == "Ready")
        #expect(after.state == .ready)
        #expect(after.action == .none)
        #expect(model.message == nil)
        #expect(WineRunnerInstaller.isInstalled(build.id, runners: runners))
        #expect(WineRunnerInstaller.verify(build.id, runners: runners).isEmpty)
        let loader = WineRunnerInstaller.dir(for: build.id, runners: runners)
            .appending(path: "lib/wine/x86_64-unix/wine")
        let signed = try await offMain { try Shell.check("/usr/bin/codesign", ["-d", "--entitlements", ":-", loader.path(percentEncoded: false)]) }
        let entitlements = try #require(try PropertyListSerialization.propertyList(
            from: Data(signed.utf8), format: nil) as? [String: Bool])
        #expect(entitlements["com.apple.security.cs.allow-dyld-environment-variables"] == true)
        #expect(entitlements["com.apple.security.cs.disable-library-validation"] == true)
        #expect(try String(contentsOf: work.appending(path: "tools"), encoding: .utf8)
            == "\(SupportPaths.toolPrefix)-\(build.id)\t\(build.id)\trosetta\tCartouche Wine 26.3\n")
        #expect(FileManager.default.isExecutableFile(atPath: work.appending(
            path: "compatibilitytools.d/\(SupportPaths.toolPrefix)-\(build.id)/run").path(percentEncoded: false)))
    }

    @Test("A damaged download leaves the runner not installed and tells the user")
    func damagedDownload() async throws {
        let build = try await fixture()
        let wrong = RunnerManifest.Build(
            id: build.id, kind: build.kind, origin: build.origin, name: build.name, version: build.version,
            displayVersion: build.displayVersion, url: build.url, size: build.size,
            sha256: String(repeating: "0", count: 64), root: build.root, loader: build.loader, flavors: build.flavors)
        let model = try model(builds: [wrong])
        await model.refresh()
        await model.download(wrong.id)

        #expect(model.message == "Something is wrong with the downloaded files. Please check for a Cartouche update.")
        let row = try #require(model.rows.first { $0.id == wrong.id })
        #expect(row.status == "Not installed")
        #expect(row.action == .download)
        #expect(!WineRunnerInstaller.isInstalled(wrong.id, runners: runners))
    }

    @Test("Without a toolkit the row reads Not found with How to Get It, and D3DMetal is not offered")
    func toolkitAbsent() async throws {
        let model = try model(builds: [])
        await model.refresh()
        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.title == "Game Porting Toolkit")
        #expect(row.status == "Not found")
        #expect(row.link == RunnersModel.Row.Link(
            title: "How to Get It", url: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!))
        #expect(offered(model).isEmpty)
    }

    // A scratch app folder holding a fixture toolkit of the given version
    func toolkitApp(_ version: String = "3.0", in parent: URL? = nil) throws -> URL {
        let apps = (parent ?? work).appending(path: "Applications-\(UUID().uuidString)")
        try PortingToolkitTests.toolkit(
            at: apps.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib"), version: version)
        return apps
    }

    @Test("A toolkit found on the Mac asks once with its size; Copy installs it and reads Ready")
    func toolkitCopy() async throws {
        let apps = try toolkitApp()
        let search = PortingToolkitSource.Search(volumes: volumes(), applications: [apps])
        let model = try model(builds: [], toolkits: { PortingToolkitSource.discover(search) })

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
        #expect(offered(model) == ["gptk-3.0"])
    }

    @Test("Use in Place records the folder, keeps no copy, and reads the framework there")
    func toolkitInPlace() async throws {
        let apps = try toolkitApp()
        let lib = apps.appending(path: "Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let search = PortingToolkitSource.Search(volumes: volumes(), applications: [apps])
        let model = try model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
        await model.refresh()

        await model.answerToolkit(.inPlace)

        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.status == "Ready")
        #expect(PortingToolkitSource.receipt(version: "3.0", runners: runners)?.inPlace
            == PortingToolkitTests.path(lib))
        #expect(!FileManager.default.fileExists(
            atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
                .appending(path: "lib").path(percentEncoded: false)))
        #expect(offered(model) == ["gptk-3.0"])
        #expect(PortingToolkitSource.libd3dshared(runners: runners).map(PortingToolkitTests.path)
            == PortingToolkitTests.path(lib.appending(path: "external/libd3dshared.dylib")))

        // The recorded folder goes away: the row says so and offers to copy anew
        try FileManager.default.removeItem(at: apps.appending(path: "Game Porting Toolkit.app"))
        await model.refresh()
        let missing = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(missing.status == "Damaged")
        #expect(missing.detail.contains("is gone"))
        #expect(missing.action == .repair)
        #expect(offered(model).isEmpty)

        let otherApps = try toolkitApp()
        model.chooseToolkitFolder = { otherApps.appending(path: "Game Porting Toolkit.app") }
        await model.perform(.repair, on: "gptk-3.0")

        let repaired = try #require(model.rows.first { $0.id == "gptk-3.0" })
        #expect(repaired.status == "Ready")
        #expect(FileManager.default.fileExists(atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
    }

    @Test("A dismissed question is not asked again, and Set Up asks it once more")
    func toolkitAskedOnce() async throws {
        let apps = try toolkitApp()
        let search = PortingToolkitSource.Search(volumes: volumes(), applications: [apps])
        let model = try model(builds: [], toolkits: { PortingToolkitSource.discover(search) })
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
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.withLock { n += 1 } }
            var value: Int { lock.withLock { n } }
        }
        let count = Count()
        let model = RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: { FreeRunnerScan(manifest: RunnerManifest.current(cache: cache)) },
            registry: { RunnerRegistry.refresh(runners: $0, roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json")!,
            manifestCache: cache, manifestKey: key,
            fetch: { url in count.bump(); return try await feed(url) }, defaults: defaults
        )
        let now = Date()
        await model.refreshManifestIfDue(now: now)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(60 * 60))
        #expect(count.value == 2)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(25 * 60 * 60))
        #expect(count.value == 4)
        await model.refresh()
        #expect(model.rows.contains { $0.title == "Cartouche Wine 26.3.0-2" })
        #expect(!model.rows.contains { $0.title == "Cartouche Wine 26.3.0-1" })

        // The daily switch pauses the manifest fetch too
        defaults.set(false, forKey: DailyChecks.key)
        await model.refreshManifestIfDue(now: now.addingTimeInterval(50 * 60 * 60))
        #expect(count.value == 4)
        // A deliberate check bypasses the daily toggle and cooldown, verifies both files,
        // and updates the catalog without downloading or installing a runner.
        await model.checkForUpdates()
        #expect(count.value == 6)
        #expect(!model.checkingForUpdates)
        #expect(model.updateStatus != nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: runners.path))?.isEmpty != false)
        defaults.removeObject(forKey: DailyChecks.key)
    }

    @Test("A toolkit still mounted on an image is copied, never linked, and asked about only on Set Up")
    func mountedToolkit() async throws {
        let image = volumes()
        let apps = try toolkitApp(in: image)
        let search = PortingToolkitSource.Search(volumes: image, applications: [apps])
        let model = try model(builds: [], toolkits: { PortingToolkitSource.discover(search) })

        await model.refresh()
        #expect(model.toolkitQuestion == nil, "an ejectable image is never asked about on sight")
        let row = try #require(model.rows.first { $0.kind == .portingToolkit })
        #expect(row.action == .setUp)

        // Use in Place is not offered: Set Up asks and copies whichever way the user answers
        await model.perform(.setUp, on: "gptk-3.0")
        #expect(model.toolkitQuestion != nil)
        await model.answerToolkit(.inPlace)
        #expect(model.toolkitQuestion == nil)

        #expect(model.rows.first { $0.kind == .portingToolkit }?.status == "Ready")
        let receipt = try #require(PortingToolkitSource.receipt(version: "3.0", runners: runners))
        #expect(receipt.inPlace == nil, "a mounted image is always copied")
        #expect(!receipt.files.isEmpty)
        #expect(FileManager.default.fileExists(atPath: PortingToolkitSource.folder(version: "3.0", runners: runners)
            .appending(path: "lib/external/D3DMetal.framework").path(percentEncoded: false)))
    }

    @Test("An unsupported free runner's row offers Remove, which deletes the install")
    func removeRunner() async throws {
        let build = try await fixture()
        try await WineRunnerInstaller.install(build, runners: runners, downloads: work.appending(path: "downloads"))
        let model = try model(builds: [])
        await model.refresh()

        let row = try #require(model.rows.first { $0.id == build.id })
        #expect(row.action == .remove)

        await model.perform(.remove, on: build.id)
        #expect(!WineRunnerInstaller.isInstalled(build.id, runners: runners))
        #expect(model.rows.allSatisfy { $0.id != build.id })
        #expect(model.message == nil)
    }

    @Test("A Wine build a game runs from is not removed, and says why")
    func removeRefusedWhileRunning() async throws {
        let build = try await fixture()
        try await WineRunnerInstaller.install(build, runners: runners, downloads: work.appending(path: "downloads"))
        let folder = WineRunnerInstaller.dir(for: build.id, runners: runners).standardizedFileURL
        let model = try model(builds: [], isRunning: { $0.standardizedFileURL == folder })
        await model.refresh()

        await model.perform(.remove, on: build.id)
        #expect(WineRunnerInstaller.isInstalled(build.id, runners: runners))
        #expect(model.message?.contains("Quit the game first") == true)
    }

    @Test("Removing the toolkit copy rewrites Steam's tool lists, and waits while a game runs")
    func removeToolkitSyncsTools() async throws {
        let apps = try toolkitApp()
        let search = PortingToolkitSource.Search(volumes: volumes(), applications: [apps])
        let synced = Counter()
        let running = Flag(true)
        let model = try model(builds: [], toolkits: { PortingToolkitSource.discover(search) },
                              isRunning: { _ in running.value }, onSync: { synced.add() })
        await model.refresh()
        await model.answerToolkit(.copy)
        let copy = PortingToolkitSource.folder(version: "3.0", runners: runners)
        let before = synced.count

        await model.perform(.remove, on: "gptk-3.0")
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(synced.count == before)

        running.value = false
        await model.perform(.remove, on: "gptk-3.0")
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(synced.count == before + 1)
    }

    @Test("A refresh that finishes after a newer one does not overwrite its list")
    func staleRefreshDropped() async throws {
        let build = try await fixture()
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        let calls = Calls()
        let model = RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            scan: {
                let n = calls.next()
                if n == 1 { Thread.sleep(forTimeInterval: 0.4) }
                return FreeRunnerScan(manifest: RunnerManifest(
                    format: 1, revision: 1, builds: n == 2 ? [build] : []))
            },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: $0.deletingLastPathComponent().appending(path: "bridge"), roots: [], manual: [], pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json"),
            defaults: defaults
        )

        async let first: () = model.refresh()
        try await Task.sleep(for: .milliseconds(50))
        await model.refresh()
        await first
        // Without the generation check, the stale empty scan would land last
        #expect(model.rows.first { $0.id == build.id } != nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
