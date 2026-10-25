
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class RunnersModel {

    struct Row: Identifiable, Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case download
            case setUp
            case repair
            case remove
            case update
            case none
        }

        struct Link: Equatable, Sendable {
            let title: String
            let url: URL
        }

        let id: String
        let kind: Runner.Kind
        let title: String
        let detail: String
        let status: String
        let state: Runner.State?
        let action: Action
        var removable = false
        var link: Link?
        // The version an Update installs, and whether one is running now
        var update: String?
        var updating = false
    }

    enum ToolkitPlacement: Sendable, Equatable {
        case copy
        case inPlace
    }

    struct ToolkitQuestion: Equatable, Sendable, Identifiable {
        let install: PortingToolkitInstall
        let copySize: Int64
        var id: String { install.id }
    }

    private(set) var rows: [Row] = []
    private(set) var registry = RunnerRegistry()
    private(set) var manifest = RunnerManifest(format: RunnerManifest.format, revision: 0, builds: [])
    private(set) var toolkits: [PortingToolkitInstall] = []
    private(set) var toolkitQuestion: ToolkitQuestion?
    private(set) var checkingForUpdates = false
    private(set) var updateStatus: String?
    private(set) var message: String?
    private(set) var busy: Set<String> = []
    private(set) var updating: Set<String> = []

    @ObservationIgnored let runnersFolder: URL
    @ObservationIgnored let downloads: URL
    @ObservationIgnored let prepareWine: @Sendable (RunnerManifest.Build, URL) throws -> Void
    @ObservationIgnored let syncTools: @Sendable (URL) throws -> Void
    @ObservationIgnored let isRunning: @Sendable (URL) -> Bool
    @ObservationIgnored let session: URLSession
    @ObservationIgnored let scan: @Sendable () -> FreeRunnerScan
    @ObservationIgnored let crossOver: @Sendable (URL, FreeRunnerScan) -> RunnerRegistry
    @ObservationIgnored let manifestFeed: URL?
    @ObservationIgnored let manifestCache: URL
    // The key a remote manifest must be signed with (the Sparkle public key)
    @ObservationIgnored let manifestKey: Curve25519.Signing.PublicKey?
    @ObservationIgnored let fetch: CompatibilityClient.Fetch
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var chooseToolkitFolder: @MainActor () -> URL? = { nil }
    // Moves games, setups and defaults from the old build to the new one; set by the app. A throw undoes the update.
    @ObservationIgnored var migrateGames: @MainActor (_ old: String, _ new: Runner) async throws -> Void = { _, _ in }
    @ObservationIgnored var didChange: @MainActor () async -> Void = {}
    @ObservationIgnored private var refreshGeneration = 0

    static let manifestCheckKey = "runnerManifestLastCheck"

    init(
        runnersFolder: URL = SupportPaths.runners,
        downloads: URL = WineRunnerInstaller.downloads,
        session: URLSession = WineRunnerInstaller.session,
        prepareWine: @escaping @Sendable (RunnerManifest.Build, URL) throws -> Void = {
            _ = try RunnerSetup.prepareWine($0, runners: $1)
        },
        syncTools: @escaping @Sendable (URL) throws -> Void = { _ = try CompatToolList.sync(runners: $0) },
        isRunning: @escaping @Sendable (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) },
        scan: @escaping @Sendable () -> FreeRunnerScan = { .standard },
        registry: @escaping @Sendable (URL, FreeRunnerScan) -> RunnerRegistry = {
            RunnerRegistry.pruneOwnBundlesOnce()
            return RunnerRegistry.refresh(runners: $0, free: $1)
        },
        manifestFeed: URL? = RunnerManifest.feed,
        manifestCache: URL = RunnerManifest.cacheFile,
        manifestKey: Curve25519.Signing.PublicKey? = RunnerManifest.signingKey(),
        fetch: @escaping CompatibilityClient.Fetch = HTTPFetch.download(
            timeout: 30, resourceTimeout: 5 * 60, userAgent: "Cartouche/\(AppVersion.bundled)"),
        defaults: UserDefaults = .standard
    ) {
        self.manifestFeed = manifestFeed
        self.manifestCache = manifestCache
        self.manifestKey = manifestKey
        self.fetch = fetch
        self.defaults = defaults
        self.runnersFolder = runnersFolder
        self.downloads = downloads
        self.session = session
        self.prepareWine = prepareWine
        self.syncTools = syncTools
        self.isRunning = isRunning
        self.scan = scan
        self.crossOver = registry
    }

    var portingToolkitMissing: Bool { !registry.runners.contains { $0.kind == .portingToolkit } }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let scan = self.scan, crossOver = self.crossOver, folder = runnersFolder
        let (scanned, listed) = await Task.detached { let s = scan(); return (s, crossOver(folder, s)) }.value
        guard generation == refreshGeneration else { return }
        manifest = scanned.manifest
        toolkits = scanned.toolkits
        registry = listed
        if toolkitQuestion == nil, let install = toolkits.first(where: unanswered) {
            let lib = install.lib
            let size = await Task.detached {
                PortingToolkitSource.copySize(of: lib.appending(path: "external"))
            }.value
            guard generation == refreshGeneration else { return }
            toolkitQuestion = ToolkitQuestion(install: install, copySize: size)
        }
        rows = makeRows()
        Task { await refreshManifestInBackground() }
    }

    private func refreshManifestInBackground() async {
        guard case .updated = await refreshManifestIfDue() else { return }
        await refresh()
    }

    private func unanswered(_ install: PortingToolkitInstall) -> Bool {
        // A mounted image is never asked about on its own: it may be gone at the next launch
        !install.mountedImage
            && registry.runner(id: install.id)?.state == .available
            && !PortingToolkitSource.isAsked(version: install.version, defaults)
    }

    func answerToolkit(_ placement: ToolkitPlacement) async {
        guard let question = toolkitQuestion else { return }
        toolkitQuestion = nil
        PortingToolkitSource.markAsked(version: question.install.version, defaults)
        await setUp(question.install, placement: placement)
        rows = makeRows()
    }

    func dismissToolkitQuestion() {
        guard let question = toolkitQuestion else { return }
        toolkitQuestion = nil
        PortingToolkitSource.markAsked(version: question.install.version, defaults)
    }

    func askToolkit(_ id: String) async {
        guard let install = toolkits.first(where: { $0.id == id }) else { return }
        let lib = install.lib
        let size = await Task.detached {
            PortingToolkitSource.copySize(of: lib.appending(path: "external"))
        }.value
        toolkitQuestion = ToolkitQuestion(install: install, copySize: size)
    }

    @discardableResult
    func refreshManifestIfDue(now: Date = .now, force: Bool = false) async -> RunnerManifest.RefreshOutcome {
        guard let feed = manifestFeed, force || DailyChecks.enabled(defaults) else { return .unavailable }
        if !force, let last = defaults.object(forKey: Self.manifestCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 60 * 60 {
            return .unchanged
        }
        let outcome = await RunnerManifest.refresh(from: feed, cache: manifestCache, fetch: fetch, key: manifestKey)
        if outcome != .unavailable { defaults.set(now, forKey: Self.manifestCheckKey) }
        return outcome
    }

    func checkForUpdates() async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        updateStatus = nil
        defer { checkingForUpdates = false }
        let outcome = await refreshManifestIfDue(force: true)
        switch outcome {
        case .updated:
            await refresh()
            updateStatus = updates.isEmpty
                ? String(localized: "Runner list updated. Your installed runners are up to date.")
                : String(localized: "Runner updates are available. Choose Update beside a runner.")
        case .unchanged:
            updateStatus = updates.isEmpty
                ? String(localized: "Your installed runners are up to date.")
                : String(localized: "Runner updates are available. Choose Update beside a runner.")
        case .unavailable:
            updateStatus = String(localized: "The runner update feed is unavailable. Your installed runners are unchanged.")
        case .rejected:
            updateStatus = String(localized: "The runner update signature could not be verified. Your installed runners are unchanged.")
        }
    }

    // Repair missing builtins and known unpatched Steam loaders once.
    func prepareMissingWineTools() async {
        let folder = runnersFolder
        let missing = manifest.builds.filter { build in
            guard build.kind == Runner.Kind.wineBuild.rawValue,
                  build.origin == .cartouche || build.origin == .winehq,
                  let root = WineRunnerInstaller.installedFolder(for: build.id, runners: folder)
            else { return false }
            let builtin = root.appending(path: "lib/wine/x86_64-windows/lsteamclient.dll")
            return !FileManager.default.fileExists(atPath: builtin.path(percentEncoded: false)) ||
                WineSteamPatches.needsPreparation(root)
        }
        for build in missing {
            let prepare = prepareWine
            do {
                try await Task.detached { try prepare(build, folder) }.value
            } catch {
                AppLog.note("Could not prepare \(build.id) for Steam: \(error.localizedDescription)")
            }
        }
    }

    func perform(_ action: Row.Action, on id: String) async {
        guard action != .none, !busy.contains(id), let runner = registry.runner(id: id) else { return }
        switch (runner.kind, action) {
        case (.wineBuild, .remove), (.portingToolkit, .remove): await remove(id)
        case (.wineBuild, .update): await update(id)
        case (.wineBuild, _): await download(id)
        case (.portingToolkit, .setUp): await askToolkit(id)
        case (.portingToolkit, _): await copy(id)
        case (.crossOver, _): return
        }
        rows = makeRows()
    }

    @discardableResult
    func download(_ id: String) async -> Bool {
        guard let build = manifest.build(id: id), build.isPinned, !busy.contains(id) else { return false }
        message = nil
        busy.insert(id)
        refreshGeneration += 1
        registry.apply(.install, to: id)
        rows = makeRows()
        do {
            try await WineRunnerInstaller.install(build, runners: runnersFolder, downloads: downloads, session: session)
            // WineHQ launches from the same receipt path. Steam still needs the builtins.
            let folder = runnersFolder, prepareWine = self.prepareWine
            try await Task.detached { try prepareWine(build, folder) }.value
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        busy.remove(id)
        await refresh()
        await didChange()
        return message == nil
    }

    func remove(_ id: String) async {
        guard !busy.contains(id), let runner = registry.runner(id: id), runner.kind != .crossOver else { return }
        message = nil
        busy.insert(id)
        rows = makeRows()
        let folder = runnersFolder, syncTools = self.syncTools, isRunning = self.isRunning
        let name = "\(runner.name) \(runner.displayVersion)"
        do {
            try await Task.detached {
                // A Wine build runs games from its folder; D3DMetal in a toolkit copy is loaded by any of them
                let used = runner.kind == .wineBuild ? WineRunnerInstaller.dir(for: id, runners: folder) : folder
                guard !isRunning(used) else {
                    throw StepFailure(step: String(localized: "Remove build"),
                                      detail: String(localized: "A game is using \(name). Quit the game first."))
                }
                switch runner.kind {
                case .wineBuild: try WineRunnerInstaller.remove(id, runners: folder)
                case .portingToolkit: try PortingToolkitSource.remove(version: runner.version, runners: folder)
                case .crossOver: return
                }
                try syncTools(folder)
            }.value
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        busy.remove(id)
        await refresh()
    }

    // Installed Wine builds: a build the manifest dropped is listed from its receipt, as unsupported
    var installedWine: Set<String> {
        Set(registry.runners.filter { runner in
            guard runner.kind == .wineBuild else { return false }
            if case .unsupported = runner.state { return true }
            return runner.isInstalled
        }.map(\.id))
    }

    var updates: [String: RunnerManifest.Build] {
        RunnerUpdate.offers(installed: installedWine, manifest: manifest)
    }

    // The new build is installed beside the old one and every game moves to it; the old one goes once no game runs from
    // it. Any failure before the games moved removes the new build and leaves the old one and every setting as they were.
    func update(_ id: String) async {
        guard let target = updates[id], !busy.contains(id), !busy.contains(target.id),
              let old = registry.runner(id: id) else { return }
        message = nil
        busy.insert(id)
        updating.insert(id)
        rows = makeRows()
        let folder = runnersFolder, prepareWine = self.prepareWine, syncTools = self.syncTools, isRunning = self.isRunning
        do {
            try await WineRunnerInstaller.install(target, runners: folder, downloads: downloads, session: session)
            try await Task.detached { try prepareWine(target, folder) }.value
            await refresh()
            guard let runner = registry.runner(id: target.id), runner.state == .ready else {
                throw StepFailure(step: RunnerMigration.step,
                                  detail: String(localized: "The download of \(target.title) has no Wine at \(target.loader)."))
            }
            try await migrateGames(id, runner)
        } catch {
            message = (error as? StepFailure)?.detail ?? error.localizedDescription
            await Task.detached {
                try? WineRunnerInstaller.remove(target.id, runners: folder)
                try? syncTools(folder)
            }.value
            finishUpdate(id)
            await refresh()
            return
        }
        let name = "\(old.name) \(RunnerUpdate.Series(id: id)?.version ?? old.displayVersion)"
        let removed = await Task.detached { () -> Bool in
            guard !isRunning(WineRunnerInstaller.dir(for: id, runners: folder)) else { return false }
            do {
                try WineRunnerInstaller.remove(id, runners: folder)
                try syncTools(folder)
                return true
            } catch {
                return false
            }
        }.value
        if !removed { message = String(localized: "\(name) stays installed until the game using it quits.") }
        finishUpdate(id)
        await refresh()
    }

    private func finishUpdate(_ id: String) {
        busy.remove(id)
        updating.remove(id)
    }

    private func copy(_ id: String) async {
        let install = toolkits.first(where: { $0.id == id }) ?? pickedToolkit()
        guard let install else {
            message = String(localized: "No Game Porting Toolkit folder was found on this Mac.")
            return
        }
        await setUp(install, placement: .copy)
    }

    func copyPickedToolkit() async {
        guard let picked = chooseToolkitFolder() else { return }
        guard let install = toolkitInstall(at: picked) else {
            message = String(localized: "The chosen folder does not contain a Game Porting Toolkit.")
            return
        }
        await setUp(install, placement: .copy)
        rows = makeRows()
    }

    private func pickedToolkit() -> PortingToolkitInstall? {
        chooseToolkitFolder().flatMap(toolkitInstall(at:))
    }

    private func toolkitInstall(at folder: URL) -> PortingToolkitInstall? {
        guard let lib = PortingToolkitSource.lib(in: folder),
              let version = PortingToolkitSource.version(ofLib: lib) else { return nil }
        PortingToolkitSource.addManualFolder(folder, defaults)
        let volumes = PortingToolkitSource.Search().volumes.standardizedFileURL.path(percentEncoded: false)
        return PortingToolkitInstall(
            lib: lib, version: version, origin: folder,
            mountedImage: folder.standardizedFileURL.path(percentEncoded: false).hasPrefix(volumes + "/"))
    }

    private func setUp(_ install: PortingToolkitInstall, placement: ToolkitPlacement) async {
        guard !busy.contains(install.id) else { return }
        busy.insert(install.id)
        rows = makeRows()
        defer { busy.remove(install.id) }
        let folder = runnersFolder
        do {
            _ = try await Task.detached {
                switch install.mountedImage ? .copy : placement {
                case .copy: return try PortingToolkitSource.copy(install, runners: folder)
                case .inPlace: return try PortingToolkitSource.useInPlace(install, runners: folder)
                }
            }.value
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    private func makeRows() -> [Row] {
        let updates = self.updates
        // A newer build of an installed series shows as the installed row's Update, not as a row of its own
        let targets = Set(updates.values.map(\.id))
        let latestCartouche = RunnerUpdate.latestCartouche(in: manifest)?.id
        var rows = registry.runners
            .filter { runner in
                runner.isInstalled || busy.contains(runner.id) ||
                    manifest.build(id: runner.id)?.origin != .cartouche ||
                    latestCartouche == nil || runner.id == latestCartouche
            }
            .filter { !(targets.contains($0.id) && !$0.isInstalled && !busy.contains($0.id)) }
            .map { row($0, update: updates[$0.id]) }
        if portingToolkitMissing {
            rows.append(Row(
                id: "gptk", kind: .portingToolkit, title: Runner.Kind.portingToolkit.name,
                detail: String(localized: "DirectX 11 and 12 through Apple’s D3DMetal"),
                status: String(localized: "Not found"), state: nil, action: .none,
                link: Row.Link(title: String(localized: "How to Get It"), url: PortingToolkitSource.howToGetIt)
            ))
        }
        return rows
    }

    private func row(_ runner: Runner, update: RunnerManifest.Build? = nil) -> Row {
        let busy = self.busy.contains(runner.id)
        let title: String
        let detail: String
        switch runner.kind {
        case .wineBuild:
            let build = manifest.build(id: runner.id)
            title = RunnerUpdate.cartoucheTitle(id: runner.id)
                ?? build?.title ?? "\(Runner.Kind.wineBuild.name) \(runner.displayVersion)"
            detail = switch build?.origin {
            case .cartouche: String(localized: "Cartouche Wine · D3DMetal, DXMT")
            case .winehq: String(localized: "WineHQ")
            case nil: String(localized: "No longer offered")
            }
        case .portingToolkit:
            title = "\(Runner.Kind.portingToolkit.name) \(runner.displayVersion)"
            detail = runner.source.map { source in
                let shown = source.pathExtension == "app" ? source.deletingLastPathComponent() : source
                var path = shown.standardizedFileURL.path(percentEncoded: false)
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                return String(localized: "Found in \(path)")
            } ?? String(localized: "Your own copy")
        case .crossOver:
            title = "\(Runner.Kind.crossOver.name) \(runner.displayVersion)"
            detail = String(localized: "Your licensed copy")
        }

        var status: String
        var action = Row.Action.none
        var removable = false
        var shown = detail
        switch runner.state {
        case .available:
            status = busy
                ? (runner.kind == .wineBuild ? String(localized: "Downloading") : String(localized: "Copying"))
                : String(localized: "Not installed")
            if runner.kind == .wineBuild {
                let build = manifest.build(id: runner.id)
                if build?.isPinned == false {
                    status = String(localized: "Awaiting release")
                } else {
                    action = .download
                }
            }
            if runner.kind == .portingToolkit { action = .setUp }
        case .installing:
            status = runner.kind == .wineBuild ? String(localized: "Downloading") : String(localized: "Copying")
        case .ready:
            status = String(localized: "Ready")
        case .damaged:
            status = String(localized: "Damaged")
            if runner.kind != .crossOver { action = .repair; removable = true }
            if runner.kind == .portingToolkit, let reason = runner.reason { shown = reason }
        case .unsupported:
            status = String(localized: "Not supported")
            if runner.kind != .crossOver { action = .remove }
        }
        let updating = self.updating.contains(runner.id)
        if updating { status = String(localized: "Updating") }
        var link: Row.Link?
        if runner.kind == .portingToolkit, runner.state == .ready,
           let newer = PortingToolkitSource.newer(
               than: registry.runners.filter { $0.kind == .portingToolkit && $0.state == .ready }.map(\.displayVersion)) {
            status = String(localized: "D3DMetal \(newer) is out")
            link = Row.Link(title: String(localized: "Get It from Apple"), url: PortingToolkitSource.howToGetIt)
        }
        if update != nil {
            switch runner.state {
            case .ready, .damaged, .unsupported: action = .update
            case .available, .installing: break
            }
        }
        return Row(
            id: runner.id, kind: runner.kind, title: title, detail: shown, status: status, state: runner.state,
            action: busy ? .none : action, removable: removable && !busy, link: link,
            update: update.map { RunnerUpdate.Series(id: $0.id)?.version ?? $0.displayVersion },
            updating: updating
        )
    }
}
