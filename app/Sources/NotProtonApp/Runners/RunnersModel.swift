// What the Runners screen shows and does. The screen itself belongs to the library
// app (P5); this is its model, reading runners only through RunnerRegistry.

import Foundation
import Observation

@MainActor
@Observable
final class RunnersModel {

    struct Row: Identifiable, Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case download
            // Download or copy again, for a damaged runner
            case repair
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
        var link: Link?
    }

    private(set) var rows: [Row] = []
    private(set) var registry = RunnerRegistry()
    private(set) var manifest = RunnerManifest(format: RunnerManifest.format, revision: 0, builds: [])
    private(set) var toolkits: [PortingToolkitInstall] = []
    // The last failure, in words for the user
    private(set) var message: String?
    private(set) var busy: Set<String> = []

    @ObservationIgnored let runnersFolder: URL
    @ObservationIgnored let downloads: URL
    @ObservationIgnored let session: URLSession
    @ObservationIgnored let scan: @Sendable () -> FreeRunnerScan
    @ObservationIgnored let crossOver: @Sendable (URL, FreeRunnerScan) -> RunnerRegistry
    // Where a newer runner manifest is published; nil checks nothing
    @ObservationIgnored let manifestFeed: URL?
    @ObservationIgnored let manifestCache: URL
    @ObservationIgnored let fetch: CompatibilityClient.Fetch
    @ObservationIgnored let defaults: UserDefaults

    static let manifestCheckKey = "runnerManifestLastCheck"

    init(
        runnersFolder: URL = SupportPaths.runners,
        downloads: URL = WineRunnerInstaller.downloads,
        session: URLSession = WineRunnerInstaller.session,
        scan: @escaping @Sendable () -> FreeRunnerScan = { .standard },
        // Tests replace this so no real CrossOver or Steam folder is read
        registry: @escaping @Sendable (URL, FreeRunnerScan) -> RunnerRegistry = { RunnerRegistry.refresh(runners: $0, free: $1) },
        manifestFeed: URL? = CompatibilityClient.feed.map(RunnerManifest.feed(fromCompatibilityFeed:)),
        manifestCache: URL = RunnerManifest.cacheFile,
        fetch: @escaping CompatibilityClient.Fetch = CompatibilityClient.download,
        defaults: UserDefaults = .standard
    ) {
        self.manifestFeed = manifestFeed
        self.manifestCache = manifestCache
        self.fetch = fetch
        self.defaults = defaults
        self.runnersFolder = runnersFolder
        self.downloads = downloads
        self.session = session
        self.scan = scan
        self.crossOver = registry
    }

    // Where D3DMetal comes from. Nil means it is not offered as a graphics backend.
    var d3dMetal: D3DMetalProvider? { registry.d3dMetal(runners: runnersFolder) }

    var portingToolkitMissing: Bool { !registry.runners.contains { $0.kind == .portingToolkit } }

    // Lists runners, and copies a toolkit the user installed since the last look
    func refresh() async {
        await refreshManifestIfDue()
        let scan = self.scan, crossOver = self.crossOver, folder = runnersFolder
        let (scanned, listed) = await Task.detached { let s = scan(); return (s, crossOver(folder, s)) }.value
        manifest = scanned.manifest
        toolkits = scanned.toolkits
        registry = listed
        for runner in registry.runners where runner.kind == .portingToolkit && runner.state == .available {
            await copy(runner.id)
        }
        rows = makeRows()
    }

    // At most once a day, like the compatibility data
    func refreshManifestIfDue(now: Date = .now) async {
        guard let feed = manifestFeed else { return }
        if let last = defaults.object(forKey: Self.manifestCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        let outcome = await RunnerManifest.refresh(from: feed, cache: manifestCache, fetch: fetch)
        if outcome != .unavailable { defaults.set(now, forKey: Self.manifestCheckKey) }
    }

    func perform(_ action: Row.Action, on id: String) async {
        guard action != .none, !busy.contains(id), let runner = registry.runner(id: id) else { return }
        switch runner.kind {
        case .wineBuild: await download(id)
        case .portingToolkit: await copy(id)
        case .crossOver: return
        }
        rows = makeRows()
    }

    func download(_ id: String) async {
        guard let build = manifest.build(id: id), !busy.contains(id) else { return }
        message = nil
        busy.insert(id)
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

    private func copy(_ id: String) async {
        guard let install = toolkits.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id)
        rows = makeRows()
        defer { busy.remove(id) }
        let folder = runnersFolder
        do {
            _ = try await Task.detached { try PortingToolkitSource.copy(install, runners: folder) }.value
        } catch let failure as StepFailure {
            message = failure.detail
        } catch {
            message = error.localizedDescription
        }
        let crossOver = self.crossOver, scan = FreeRunnerScan(manifest: manifest, toolkits: toolkits)
        registry = await Task.detached { crossOver(folder, scan) }.value
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
            case .cartouche: String(localized: "Built by Cartouche from CodeWeavers’ open-source code")
            case .winehq: String(localized: "Official WineHQ build, less tuned for games")
            case nil: String(localized: "No longer offered")
            }
        case .portingToolkit:
            title = "\(Runner.Kind.portingToolkit.name) \(runner.displayVersion)"
            // An app is named by its folder, as in "Found in /Applications"
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

        let status: String
        var action = Row.Action.none
        switch runner.state {
        case .available:
            status = busy ? String(localized: "Copying") : String(localized: "Not installed")
            if runner.kind == .wineBuild { action = .download }
        case .installing:
            status = runner.kind == .wineBuild ? String(localized: "Downloading") : String(localized: "Copying")
        case .ready:
            status = String(localized: "Ready")
        case .damaged:
            status = String(localized: "Damaged")
            if runner.kind != .crossOver { action = .repair }
        case .unsupported:
            status = String(localized: "Not supported")
        }
        return Row(
            id: runner.id, kind: runner.kind, title: title, detail: detail, status: status, state: runner.state,
            action: busy ? .none : action
        )
    }
}
