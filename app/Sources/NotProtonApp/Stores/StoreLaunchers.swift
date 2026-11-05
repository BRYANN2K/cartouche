// The official launchers as the library sees them: installed through their pinned vendor
// installers, opened on demand, and summed up per store as one step for the store page.

import Foundation
import Synchronization

enum LauncherState: Equatable, Sendable {
    case notInstalled, starting, ready, installing
    case downloading(Double?)
    case installFailed(String)
    case startFailed(String)
}

// What the store page offers right now.
enum LauncherStep: Equatable, Sendable {
    enum Retry: Equatable, Sendable { case install, start, signIn }

    case install, signIn, waiting, starting
    case installing(Double?)
    case failed(String, retry: Retry)
}

// The vendors replace these files in place at the same URL, so a hash would break on their next
// release. What stands in for one: HTTPS, the vendor's own hosts at every hop, a size that fits,
// and the SHA-256 in the log. The installer only ever runs in the launcher's dedicated prefix.
struct LauncherInstaller: Equatable, Sendable {
    let store: GameSource
    let url: URL
    let hosts: Set<String>
    let sizes: ClosedRange<Int64>

    private static let megabyte: Int64 = 1_000_000

    static func official(_ store: GameSource) -> LauncherInstaller? {
        switch store {
        case .ubisoft:
            LauncherInstaller(store: store,
                              url: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
                              hosts: ["static3.cdn.ubi.com", "ubistatic3-a.akamaihd.net"],
                              sizes: (50 * megabyte)...(800 * megabyte))
        case .ea:
            // A bootstrapper: the launcher itself comes down with it, into the same prefix.
            LauncherInstaller(store: store,
                              url: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
                              hosts: ["origin-a.akamaihd.net"],
                              sizes: (1 * megabyte)...(100 * megabyte))
        default: nil
        }
    }

    func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return hosts.contains(host)
    }

    @Sendable static func fetch(_ installer: LauncherInstaller, into folder: URL,
                                fraction: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await installer.download(into: folder, session: PinnedDownload.session, fraction: fraction) { AppLog.note($0) }
    }

    private var refused: StoreError {
        .failed(String(localized: "Cartouche refused the \(store.name) installer: it came from an unexpected address."))
    }

    private var wrongSize: StoreError {
        .failed(String(localized: "Cartouche refused the \(store.name) installer: its size is not what was expected."))
    }

    private var unreachable: StoreError {
        .failed(String(localized: "Cartouche could not download the \(store.name) installer. Try again."))
    }

    func download(into folder: URL, session: URLSession, fraction: @escaping @Sendable (Double) -> Void,
                  log: (String) -> Void) async throws -> URL {
        guard allows(url) else { throw refused }
        let watch = InstallerWatch(self, fraction: fraction)
        let body: URL, response: URLResponse
        do {
            (body, response) = try await session.download(from: url, delegate: watch)
        } catch {
            if watch.broke == .address { throw refused }
            if watch.broke == .size { throw wrongSize }
            try Task.checkCancellation()
            throw unreachable
        }
        defer { try? FileManager.default.removeItem(at: body) }
        guard allows(response.url) else { throw refused }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw unreachable }
        let size = (try? FileManager.default.attributesOfItem(atPath: body.path(percentEncoded: false))[.size] as? Int64) ?? -1
        guard sizes.contains(size) else { throw wrongSize }
        let sha256 = try Digest.sha256(of: body)
        log("store: \(store.id) installer from \(response.url?.host() ?? ""), \(size) bytes, sha256 \(sha256)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: body, to: file)
        return file
    }
}

// Follows one download: the fraction out, and a stop at the first hop off the list or past the bound.
private final class InstallerWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Break: Sendable { case address, size }

    private let installer: LauncherInstaller
    private let fraction: @Sendable (Double) -> Void
    private let stopped = Mutex<Break?>(nil)
    private var observation: NSKeyValueObservation?

    var broke: Break? { stopped.withLock { $0 } }

    init(_ installer: LauncherInstaller, fraction: @escaping @Sendable (Double) -> Void) {
        self.installer = installer
        self.fraction = fraction
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let limit = installer.sizes.upperBound
        observation = task.progress.observe(\.fractionCompleted) { [weak self, weak task] progress, _ in
            guard let self else { return }
            guard max(progress.totalUnitCount, progress.completedUnitCount) <= limit else {
                self.stopped.withLock { $0 = .size }
                task?.cancel()
                return
            }
            self.fraction(progress.fractionCompleted)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if installer.allows(request.url) { return request }
        stopped.withLock { $0 = .address }
        task.cancel()
        return nil
    }
}

extension GameSource {
    // EAAdapter.experimental is the one switch: off, EA is in no list.
    static var offered: [GameSource] { offered(ea: EAAdapter.experimental) }
    static func offered(ea: Bool) -> [GameSource] { pc.filter { $0 != .ea || ea } }
    var isOffered: Bool { Self.offered.contains(self) }
    var isExperimental: Bool { self == .ea && EAAdapter.experimental }
}

extension UbisoftAdapter {
    var officialLauncher: StoreLauncher? { launcher }
}

extension EAAdapter {
    var officialLauncher: StoreLauncher? { launcher }
}

extension StoreConnection {
    // Ubisoft's account is the cache's user id: never shown.
    static func shownAccount(_ account: String) -> String {
        let name = UbisoftLocalCache.account(account)
        return UUID(uuidString: name) == nil ? name : ""
    }
}

extension StoreCenter {
    static var offered: [GameSource] { stores.filter(\.isOffered) }

    // An exit with an error this soon after the launch is a failed start, not a user quitting.
    static let launcherGrace: TimeInterval = 20

    func launcherState(_ store: GameSource) -> LauncherState? {
        guard let adapter = adapter(store), adapter.isAvailable, let launcher = adapter.officialLauncher else { return nil }
        return launcherActivity[store] ?? (launcher.installed ? .ready : .notInstalled)
    }

    func launcherStep(_ store: GameSource) -> LauncherStep? {
        guard let state = launcherState(store) else { return nil }
        switch state {
        case .notInstalled: return .install
        case .downloading(let fraction): return .installing(fraction)
        case .installing: return .installing(nil)
        case .starting: return .starting
        case .installFailed(let message): return .failed(message, retry: .install)
        case .startFailed(let message): return .failed(message, retry: .start)
        case .ready:
            guard let session = signIn, session.store == store else { return .signIn }
            if case .failed(let message) = session.state { return .failed(message, retry: .signIn) }
            return .waiting
        }
    }

    func signedInLauncher(_ item: SidebarItem) -> GameSource? {
        guard case .source(let store) = item, connection(store).isSignedIn, launcherState(store) != nil else { return nil }
        return store
    }

    func installLauncher(_ store: GameSource) {
        guard launcherInstalls[store] == nil, let installer = LauncherInstaller.official(store),
              let launcher = launcherState(store) != nil ? adapter(store)?.officialLauncher : nil, !launcher.installed else { return }
        let folder = folders.launcher(store).appending(path: "installer", directoryHint: .isDirectory)
        let fetch = fetchInstaller, run = runInstaller
        launcherActivity[store] = .downloading(nil)
        launcherInstalls[store] = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let file = try await fetch(installer, folder) { fraction in
                    Task { @MainActor in self?.noteDownload(store, fraction) }
                }
                try Task.checkCancellation()
                self?.launcherActivity[store] = .installing
                try await run(launcher, file)
                self?.launcherActivity[store] = nil
            } catch {
                self?.launcherActivity[store] = Task.isCancelled ? nil : .installFailed(error.localizedDescription)
            }
            self?.launcherInstalls[store] = nil
        }
    }

    func cancelLauncherInstall(_ store: GameSource) {
        launcherInstalls[store]?.cancel()
    }

    private func noteDownload(_ store: GameSource, _ fraction: Double) {
        guard case .downloading = launcherActivity[store] else { return }
        launcherActivity[store] = .downloading(fraction > 0 ? fraction : nil)
    }

    func openLauncher(_ store: GameSource) async {
        guard launcherState(store) != nil, launcherInstalls[store] == nil, let adapter = adapter(store) else { return }
        launcherActivity[store] = .starting
        let opened = now()
        do {
            let process = try await adapter.openLauncher()
            launcherActivity[store] = nil
            Task { [weak self] in
                let status = await process.wait()
                guard status != 0, let self, self.now().timeIntervalSince(opened) < Self.launcherGrace else { return }
                self.launcherFailed(store, String(localized: "\(store.name) closed right after it started."))
            }
        } catch {
            launcherFailed(store, error.localizedDescription)
        }
    }

    // Signed in, the page is the game grid: the banner says it instead.
    private func launcherFailed(_ store: GameSource, _ message: String) {
        if connection(store).isSignedIn {
            launcherActivity[store] = nil
            problem = message
        } else {
            launcherActivity[store] = .startFailed(message)
        }
    }

    func openStore(_ store: GameSource) async {
        guard launcherState(store) != nil, let adapter = adapter(store) else { return }
        do {
            try await adapter.openStorePage(nil)
        } catch {
            problem = error.localizedDescription
        }
    }
}
