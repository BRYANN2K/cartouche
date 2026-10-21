
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
    private(set) var message: String?
    private(set) var busy: Set<String> = []

    @ObservationIgnored let runnersFolder: URL
    @ObservationIgnored let downloads: URL
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
    @ObservationIgnored private var refreshGeneration = 0

    static let manifestCheckKey = "runnerManifestLastCheck"

    init(
        runnersFolder: URL = SupportPaths.runners,
        downloads: URL = WineRunnerInstaller.downloads,
        session: URLSession = WineRunnerInstaller.session,
        scan: @escaping @Sendable () -> FreeRunnerScan = { .standard },
        registry: @escaping @Sendable (URL, FreeRunnerScan) -> RunnerRegistry = { RunnerRegistry.refresh(runners: $0, free: $1) },
        manifestFeed: URL? = CompatibilityClient.feed.map(RunnerManifest.feed(fromCompatibilityFeed:)),
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
    func refreshManifestIfDue(now: Date = .now) async -> RunnerManifest.RefreshOutcome {
        guard let feed = manifestFeed, DailyChecks.enabled(defaults) else { return .unavailable }
        if let last = defaults.object(forKey: Self.manifestCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 60 * 60 {
            return .unchanged
        }
        let outcome = await RunnerManifest.refresh(from: feed, cache: manifestCache, fetch: fetch, key: manifestKey)
        if outcome != .unavailable { defaults.set(now, forKey: Self.manifestCheckKey) }
        return outcome
    }

    func perform(_ action: Row.Action, on id: String) async {
        guard action != .none, !busy.contains(id), let runner = registry.runner(id: id) else { return }
        switch (runner.kind, action) {
        case (.wineBuild, .remove), (.portingToolkit, .remove): await remove(id)
        case (.wineBuild, _): await download(id)
        case (.portingToolkit, .setUp): await askToolkit(id)
        case (.portingToolkit, _): await copy(id)
        case (.crossOver, _): return
        }
        rows = makeRows()
    }

    func download(_ id: String) async {
        guard let build = manifest.build(id: id), build.isPinned, !busy.contains(id) else { return }
        message = nil
        busy.insert(id)
        refreshGeneration += 1
        registry.apply(.install, to: id)
        rows = makeRows()
        do {
            try await WineRunnerInstaller.install(build, runners: runnersFolder, downloads: downloads, session: session)
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        busy.remove(id)
        await refresh()
    }

    func remove(_ id: String) async {
        guard !busy.contains(id), let runner = registry.runner(id: id), runner.kind != .crossOver else { return }
        message = nil
        busy.insert(id)
        rows = makeRows()
        let folder = runnersFolder
        do {
            try await Task.detached {
                switch runner.kind {
                case .wineBuild: try WineRunnerInstaller.remove(id, runners: folder)
                case .portingToolkit: try PortingToolkitSource.remove(version: runner.version, runners: folder)
                case .crossOver: break
                }
            }.value
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        busy.remove(id)
        await refresh()
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
        var rows = registry.runners.map(row)
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

    private func row(_ runner: Runner) -> Row {
        let busy = self.busy.contains(runner.id)
        let title: String
        let detail: String
        switch runner.kind {
        case .wineBuild:
            let build = manifest.build(id: runner.id)
            title = build?.title ?? "\(Runner.Kind.wineBuild.name) \(runner.displayVersion)"
            detail = switch build?.origin {
            case .cartouche: String(localized: "Built by Cartouche from CodeWeavers’ open-source code. Best for games: D3DMetal and DXMT.")
            case .winehq: String(localized: "Official WineHQ build, less tuned for games")
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
        return Row(
            id: runner.id, kind: runner.kind, title: title, detail: shown, status: status, state: runner.state,
            action: busy ? .none : action, removable: removable && !busy
        )
    }
}
