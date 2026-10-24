import Foundation
import Testing

@testable import NotProtonApp

// Updates of installed runners and graphics backends, on scratch folders: no real runners
// folder, game, Steam or network is touched.
@Suite("Runner and backend updates")
struct RunnerUpdateTests {

    let work: URL
    let runners: URL
    let installs: URL

    init() throws {
        work = try scratchDirectory("runner-update")
        runners = work.appending(path: "runners")
        installs = work.appending(path: "installs")
    }

    static func pin(_ id: String, origin: RunnerManifest.Build.Origin = .cartouche, pending: Bool = false) -> RunnerManifest.Build {
        RunnerManifest.Build(
            id: id, kind: "wineBuild", origin: origin, name: origin == .cartouche ? "Cartouche Wine" : "Wine",
            version: "26.3.0", displayVersion: "26.3",
            url: URL(string: "https://github.com/BRYANN2K/cartouche-wine/releases/download/\(id)/\(id)-x86_64.tar.xz")!,
            size: pending ? 0 : 1234, sha256: pending ? RunnerManifest.pendingSHA256 : String(repeating: "ab", count: 32),
            root: id, loader: "bin/wine", flavors: ["rosetta"])
    }

    static func manifest(_ builds: [RunnerManifest.Build]) -> RunnerManifest {
        RunnerManifest(format: 1, revision: 3, builds: builds)
    }

    // MARK: Detection

    @Test("A runner id splits into its series and version")
    func series() {
        #expect(RunnerUpdate.Series(id: "wine-crossover-26.3.0-1") == RunnerUpdate.Series(id: "wine-crossover-26.3.0-1"))
        #expect(RunnerUpdate.Series(id: "wine-crossover-26.3.0-1")?.family == "wine-crossover")
        #expect(RunnerUpdate.Series(id: "wine-crossover-26.3.0-1")?.version == "26.3.0-1")
        #expect(RunnerUpdate.Series(id: "wine-stable-11.0_1")?.family == "wine-stable")
        #expect(RunnerUpdate.Series(id: "gptk") == nil)
        #expect(RunnerUpdate.cartoucheTitle(id: "wine-crossover-26.3.0-1") == "Cartouche Wine 26.3.0-1")
        #expect(RunnerUpdate.cartoucheTitle(id: "wine-devel-11.18") == nil)
    }

    @Test("The same version with a higher revision is offered as the update")
    func newerRevision() {
        let manifest = Self.manifest([Self.pin("wine-crossover-26.3.0-1"), Self.pin("wine-crossover-26.3.0-2")])
        let offer = RunnerUpdate.offer(for: "wine-crossover-26.3.0-1", in: manifest, installed: ["wine-crossover-26.3.0-1"])
        #expect(offer?.id == "wine-crossover-26.3.0-2")
        // Revisions compare as numbers, not text
        let ten = Self.manifest([Self.pin("wine-crossover-26.3.0-9"), Self.pin("wine-crossover-26.3.0-10")])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-9", in: ten, installed: ["wine-crossover-26.3.0-9"])?.id
            == "wine-crossover-26.3.0-10")
    }

    @Test("A higher version is offered, the newest one when several are")
    func newerVersion() {
        let manifest = Self.manifest([
            Self.pin("wine-crossover-26.3.0-1"), Self.pin("wine-crossover-26.3.0-2"), Self.pin("wine-crossover-26.10.0-1"),
        ])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-1", in: manifest, installed: ["wine-crossover-26.3.0-1"])?.id
            == "wine-crossover-26.10.0-1")
        // An installed build the manifest no longer lists still gets its update
        let dropped = Self.manifest([Self.pin("wine-crossover-26.3.0-2")])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-1", in: dropped, installed: ["wine-crossover-26.3.0-1"])?.id
            == "wine-crossover-26.3.0-2")
    }

    @Test("Nothing is offered when no listed build is newer, pinned, of the same series and not installed")
    func notOffered() {
        let installed: Set<String> = ["wine-crossover-26.3.0-2"]
        let older = Self.manifest([Self.pin("wine-crossover-26.3.0-1"), Self.pin("wine-crossover-26.3.0-2")])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-2", in: older, installed: installed) == nil)
        let otherSeries = Self.manifest([Self.pin("wine-crossover-26.3.0-2"), Self.pin("wine-devel-27.0", origin: .winehq)])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-2", in: otherSeries, installed: installed) == nil)
        let pending = Self.manifest([Self.pin("wine-crossover-26.3.0-2"), Self.pin("wine-crossover-26.3.0-3", pending: true)])
        #expect(RunnerUpdate.offer(for: "wine-crossover-26.3.0-2", in: pending, installed: installed) == nil)
        let both = Self.manifest([Self.pin("wine-crossover-26.3.0-1"), Self.pin("wine-crossover-26.3.0-2")])
        #expect(RunnerUpdate.offers(installed: ["wine-crossover-26.3.0-1", "wine-crossover-26.3.0-2"], manifest: both).isEmpty)
    }

    // MARK: Moving games

    func installWine(_ id: String) throws {
        let bin = runners.appending(path: "\(id)/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appending(path: "wine")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path(percentEncoded: false))
    }

    @discardableResult
    func game(_ id: String, runner: String) throws -> GameFolder {
        let folder = GameFolder(root: installs.appending(path: id))
        try FileManager.default.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        try InstalledGames.save(InstalledGame(
            id: id, name: id, runnerID: runner, graphics: GraphicsBackend.wined3d.rawValue,
            prefix: folder.prefix.path(percentEncoded: false),
            exe: folder.prefix.appending(path: "drive_c/Games/\(id)/game.exe").path(percentEncoded: false),
            installedAt: Date(), installerFolder: "/x", redistributables: []), in: folder)
        try Data("#!/bin/sh\n# old launcher of \(id)\n".utf8).write(to: folder.launcher)
        return folder
    }

    func runner(_ id: String) -> Runner {
        Runner(id: id, kind: .wineBuild, version: "26.3.0", displayVersion: "26.3", flavors: [.rosetta],
               state: .ready, build: nil, source: nil, isInstalled: true)
    }

    func job(_ folder: GameFolder) -> RunnerMigration.Job {
        RunnerMigration.Job(folder: folder, backend: .wined3d, environment: ["DXMT_LOG_LEVEL": "none"])
    }

    @Test("Games on the old build move to the new one: record and launcher; other games stay")
    func movesGames() throws {
        let old = "wine-crossover-26.3.0-1", new = "wine-crossover-26.3.0-2"
        try installWine(new)
        let a = try game("a", runner: old)
        let b = try game("b", runner: old)
        let other = try game("c", runner: "wine-devel-11.18")
        let untouched = try Data(contentsOf: other.launcher)

        try RunnerMigration.move([job(a), job(b)], to: runner(new), runners: runners, backends: work.appending(path: "backends"))

        for folder in [a, b] {
            let record = try #require(InstalledGames.record(in: folder))
            #expect(record.runnerID == new)
            #expect(record.wineRunnerKind == Runner.Kind.wineBuild.rawValue)
            let launcher = try String(contentsOf: folder.launcher, encoding: .utf8)
            #expect(launcher.contains(runners.appending(path: new).path(percentEncoded: false)))
            #expect(!launcher.contains(old))
            #expect(launcher.contains("DXMT_LOG_LEVEL"))
            #expect(FileManager.default.isExecutableFile(atPath: folder.launcher.path(percentEncoded: false)))
        }
        #expect(InstalledGames.record(in: other)?.runnerID == "wine-devel-11.18")
        #expect(try Data(contentsOf: other.launcher) == untouched)
    }

    @Test("Setups and the default naming the old build name the new one; others stay")
    func movesSetups() {
        var choices = LibraryChoices()
        choices.setups["installer:a"] = GameSetupChoice(runnerID: "old", graphics: .dxmt)
        choices.setups["epic:x"] = GameSetupChoice(runnerID: "old")
        choices.setups["steam:1"] = GameSetupChoice(runnerID: "other")
        choices.favorites = ["epic:x"]
        let (moved, ids) = RunnerMigration.replacing("old", with: "new", in: choices)
        #expect(ids == ["epic:x", "installer:a"])
        #expect(moved.setups["installer:a"] == GameSetupChoice(runnerID: "new", graphics: .dxmt))
        #expect(moved.setups["epic:x"]?.runnerID == "new")
        #expect(moved.setups["steam:1"]?.runnerID == "other")
        #expect(moved.favorites == ["epic:x"])

        #expect(RunnerMigration.replacing("old", with: "new", in: SetupDefaults(runnerID: "old", graphics: .dxvk))
            == SetupDefaults(runnerID: "new", graphics: .dxvk))
        #expect(RunnerMigration.replacing("old", with: "new", in: SetupDefaults(runnerID: "other")) == nil)
    }

    @Test("A failure on one game puts every game already moved back as it was")
    func failureRestores() throws {
        let old = "wine-crossover-26.3.0-1", new = "wine-crossover-26.3.0-2"
        try installWine(new)
        let a = try game("a", runner: old)
        let b = try game("b", runner: old)
        let before = try (Data(contentsOf: a.record), Data(contentsOf: a.launcher))
        // b's launcher can't be replaced: a folder holding a file sits where it goes
        try FileManager.default.removeItem(at: b.launcher)
        try FileManager.default.createDirectory(at: b.launcher, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: b.launcher.appending(path: "keep"))

        #expect(throws: (any Error).self) {
            try RunnerMigration.move([job(a), job(b)], to: runner(new), runners: runners, backends: work.appending(path: "backends"))
        }
        #expect(try Data(contentsOf: a.record) == before.0)
        #expect(try Data(contentsOf: a.launcher) == before.1)
        #expect(InstalledGames.record(in: b)?.runnerID == old)
    }

    @Test("A new build that can't start Wine changes no game")
    func noWine() throws {
        let a = try game("a", runner: "wine-crossover-26.3.0-1")
        let before = try Data(contentsOf: a.launcher)
        #expect(throws: StepFailure.self) {
            try RunnerMigration.move([job(a)], to: runner("wine-crossover-26.3.0-2"), runners: runners,
                                     backends: work.appending(path: "backends"))
        }
        #expect(InstalledGames.record(in: a)?.runnerID == "wine-crossover-26.3.0-1")
        #expect(try Data(contentsOf: a.launcher) == before)
    }

    // MARK: Graphics backends

    func backendPin(_ version: String) -> BackendManifest.Pin {
        BackendManifest.Pin(
            backend: .dxmt, name: "DXMT", version: version, license: "MIT",
            url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v\(version)/dxmt.tar.gz")!,
            size: 1, sha256: String(repeating: "cd", count: 32), files: ["x86_64-windows/d3d11.dll"])
    }

    func receipt(_ version: String) -> BackendInstaller.Receipt {
        BackendInstaller.Receipt(backend: .dxmt, version: version, archiveSHA256: "", files: [:])
    }

    @Test("A newer pinned backend than the receipt is an update; the same or an older one is ready")
    func backendOffer() {
        #expect(BackendInstaller.offer(backendPin("0.90"), installed: receipt("0.80")) == .update(to: "0.90"))
        #expect(BackendInstaller.offer(backendPin("0.100"), installed: receipt("0.90")) == .update(to: "0.100"))
        #expect(BackendInstaller.offer(backendPin("0.80"), installed: receipt("0.80")) == .ready)
        #expect(BackendInstaller.offer(backendPin("0.70"), installed: receipt("0.80")) == .ready)
        #expect(BackendInstaller.offer(backendPin("0.80"), installed: nil) == .download)
    }

    // MARK: Stray CrossOver rows

    func bundle(_ url: URL, info: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: "Contents/SharedSupport/CrossOver/lib/wine"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
    }

    @Test("Cartouche's own runner folders and Steam copies are never listed as CrossOver")
    func ownFoldersIgnored() throws {
        let compat = work.appending(path: "compatibilitytools.d")
        let ownRunner = runners.appending(path: "wine-crossover-26.3.0-1")
        let ownCopy = compat.appending(path: "cartouche-wine-crossover-26.3.0-1.app")
        let renamed = work.appending(path: "Elsewhere/Cartouche Wine.app")
        let folder = work.appending(path: "Elsewhere/CrossOver-folder")
        let real = work.appending(path: "Elsewhere/CrossOver.app")
        try bundle(ownRunner, info: ["CFBundleShortVersionString": "wine-crossover-26.3.0-1"])
        try bundle(ownCopy, info: ["CFBundleShortVersionString": "26.3"])
        try bundle(renamed, info: ["CFBundleShortVersionString": "wine-crossover-26.3.0-1"])
        try bundle(folder, info: ["CFBundleShortVersionString": "26.3"])
        try bundle(real, info: ["CFBundleShortVersionString": "26.3", "CFBundleIdentifier": "com.codeweavers.CrossOver"])

        let found = CrossOverSource.discover(
            roots: [], manual: [ownRunner, ownCopy, renamed, folder, real], pins: [], excluding: [runners, compat])
        #expect(found.map(\.bundle) == [real])

        // A clone folder named after a Wine id is no orphaned CrossOver build either
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: "wine-crossover-26.3.0-1", runners: runners).appending(path: "lib/wine"),
            withIntermediateDirectories: true)
        #expect(RunnerStore.orphanedClones(in: runners, pins: []).isEmpty)
        let registry = RunnerRegistry.refresh(
            runners: runners, bridge: work.appending(path: "bridge"), roots: [], manual: [ownRunner, renamed],
            pins: [], fexAvailable: true)
        #expect(!registry.runners.contains { $0.kind == .crossOver })
    }

    @Test("Stale manual entries pointing at Cartouche's own builds are pruned once")
    func pruneOnce() throws {
        let name = "runner-update-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let ownRunner = runners.appending(path: "wine-crossover-26.3.0-1")
        let real = work.appending(path: "Elsewhere/CrossOver.app")
        try bundle(real, info: ["CFBundleShortVersionString": "26.3"])
        CrossOverSource.setManualBundles([ownRunner, real], defaults)

        CrossOverSource.pruneOwnBundlesOnce(defaults, excluding: [runners])
        #expect(CrossOverSource.manualBundles(defaults).map(\.lastPathComponent) == ["CrossOver.app"])

        CrossOverSource.setManualBundles([ownRunner, real], defaults)
        CrossOverSource.pruneOwnBundlesOnce(defaults, excluding: [runners])
        #expect(CrossOverSource.manualBundles(defaults).count == 2)
    }
}

// The Update button on Settings > Runners, on fixture archives served from file URLs.
@Suite("Runner update in Settings")
@MainActor
final class RunnerUpdateModelTests {

    let work: URL
    let runners: URL
    let old = "wine-crossover-26.3.0-1"
    let new = "wine-crossover-26.3.0-2"

    init() throws {
        work = try scratchDirectory("runner-update-model")
        runners = work.appending(path: "runners")
    }

    deinit { try? FileManager.default.removeItem(at: work) }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }

    func builds(damagedNew: Bool = false) async throws -> (RunnerManifest.Build, RunnerManifest.Build) {
        let work = self.work, old = self.old, new = self.new
        let (oldArchive, newArchive) = try await offMain {
            (try WineRunnerInstallerTests.archive(id: old, in: work),
             try WineRunnerInstallerTests.archive(id: new, in: work, named: "\(new)-x86_64.tar.xz"))
        }
        let oldBuild = try WineRunnerInstallerTests.build(id: old, for: oldArchive)
        let newBuild = try WineRunnerInstallerTests.build(
            id: new, for: newArchive, sha256: damagedNew ? String(repeating: "0", count: 64) : nil)
        try await WineRunnerInstaller.install(oldBuild, runners: runners, downloads: work.appending(path: "downloads"))
        return (oldBuild, newBuild)
    }

    func model(_ builds: [RunnerManifest.Build], running: Bool = false, calls: Calls) -> RunnersModel {
        let bridge = work.appending(path: "bridge")
        let model = RunnersModel(
            runnersFolder: runners, downloads: work.appending(path: "downloads"),
            prepareWine: { _, _ in }, syncTools: { _ in calls.add("sync") },
            isRunning: { _ in running },
            scan: { FreeRunnerScan(manifest: RunnerManifest(format: 1, revision: 1, builds: builds)) },
            registry: { RunnerRegistry.refresh(runners: $0, bridge: bridge, roots: [], manual: [],
                                               pins: [], fexAvailable: true, free: $1) },
            manifestFeed: nil, manifestCache: work.appending(path: "runners.json"))
        model.migrateGames = { old, new in calls.add("migrate \(old) \(new.id)") }
        return model
    }

    @Test("The installed row offers the update; the new build has no row of its own")
    func offered() async throws {
        let (oldBuild, newBuild) = try await builds()
        let model = model([oldBuild, newBuild], calls: Calls())
        await model.refresh()
        let row = try #require(model.rows.first { $0.id == old })
        #expect(row.title == "Cartouche Wine 26.3.0-1")
        #expect(row.status == "Ready")
        #expect(row.action == .update)
        #expect(row.update == "26.3.0-2")
        #expect(!model.rows.contains { $0.id == new })
    }

    @Test("Update installs the new build, moves the games, then removes the old build")
    func updates() async throws {
        let (oldBuild, newBuild) = try await builds()
        let calls = Calls()
        let model = model([oldBuild, newBuild], calls: calls)
        await model.refresh()
        await model.perform(.update, on: old)

        #expect(model.message == nil)
        #expect(calls.all.first == "migrate \(old) \(new)")
        #expect(WineRunnerInstaller.isInstalled(new, runners: runners))
        #expect(!WineRunnerInstaller.isInstalled(old, runners: runners))
        #expect(model.rows.first { $0.id == new }?.status == "Ready")
    }

    @Test("A running game keeps the old build installed after its games moved")
    func runningKeepsOld() async throws {
        let (oldBuild, newBuild) = try await builds()
        let calls = Calls()
        let model = model([oldBuild, newBuild], running: true, calls: calls)
        await model.refresh()
        await model.perform(.update, on: old)

        #expect(calls.all.contains("migrate \(old) \(new)"))
        #expect(WineRunnerInstaller.isInstalled(new, runners: runners))
        #expect(WineRunnerInstaller.isInstalled(old, runners: runners))
        #expect(model.message == "Cartouche Wine 26.3.0-1 stays installed until the game using it quits.")
    }

    @Test("A failed download keeps the old build and moves nothing")
    func failedDownload() async throws {
        let (oldBuild, newBuild) = try await builds(damagedNew: true)
        let calls = Calls()
        let model = model([oldBuild, newBuild], calls: calls)
        await model.refresh()
        await model.perform(.update, on: old)

        #expect(model.message != nil)
        #expect(!calls.all.contains { $0.hasPrefix("migrate") })
        #expect(WineRunnerInstaller.isInstalled(old, runners: runners))
        #expect(!WineRunnerInstaller.isInstalled(new, runners: runners))
        #expect(model.rows.first { $0.id == old }?.action == .update)
    }

    @Test("A failed move removes the new build and keeps the old one")
    func failedMove() async throws {
        let (oldBuild, newBuild) = try await builds()
        let calls = Calls()
        let model = model([oldBuild, newBuild], calls: calls)
        model.migrateGames = { _, _ in
            throw StepFailure(step: RunnerMigration.step, detail: "game folder is read-only")
        }
        await model.refresh()
        await model.perform(.update, on: old)

        #expect(model.message == "game folder is read-only")
        #expect(WineRunnerInstaller.isInstalled(old, runners: runners))
        #expect(!WineRunnerInstaller.isInstalled(new, runners: runners))
    }
}
