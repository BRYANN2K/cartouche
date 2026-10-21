// Reads Steam's files off the main actor on an adaptive interval — fast while bytes move,
// slower when nothing does, slowest while Steam is closed — and watches the folders the
// files live in so a rewrite lands before the next tick. Stamps each snapshot with the
// download rate and whether Steam is running: a closed client leaves stale flags behind,
// so while it is closed nothing counts as downloading or running.

import Dispatch
import Foundation

actor SteamDownloadMonitor {

    struct Reading: Sendable {
        var snapshot: SteamActivitySnapshot
        // How long the caller should wait before polling again
        var interval: Duration
    }

    static let activeInterval: Duration = .seconds(1)
    static let waitingInterval: Duration = .seconds(3)
    static let idleInterval: Duration = .seconds(10)
    static let closedInterval: Duration = .seconds(30)

    let reader: SteamActivityReader
    private let isSteamRunning: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    private var rates = RateTracker()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watched: [String] = []
    private var onChange: (@Sendable () -> Void)?
    private var pending: Task<Void, Never>?

    init(reader: SteamActivityReader = SteamActivityReader(),
         isSteamRunning: (@Sendable () -> Bool)? = nil,
         now: (@Sendable () -> Date)? = nil) {
        self.reader = reader
        self.isSteamRunning = isSteamRunning ?? GameProcesses.steamIsRunning
        self.now = now ?? { Date() }
    }

    func poll() -> Reading {
        var snapshot = reader.read()
        snapshot.steamRunning = isSteamRunning()
        if !snapshot.steamRunning {
            snapshot.runningAppID = nil
            snapshot.trackedPIDs = [:]
            for i in snapshot.downloads.indices where snapshot.downloads[i].state == .downloading {
                snapshot.downloads[i].state = .paused
            }
        }
        let speeds = rates.rates(for: snapshot.downloads, now: now())
        for i in snapshot.downloads.indices {
            snapshot.downloads[i].bytesPerSecond = speeds[snapshot.downloads[i].appID] ?? 0
        }
        return Reading(snapshot: snapshot, interval: Self.interval(after: snapshot))
    }

    static func interval(after snapshot: SteamActivitySnapshot) -> Duration {
        guard snapshot.steamRunning else { return closedInterval }
        if snapshot.downloads.contains(where: { $0.state == .downloading }) { return activeInterval }
        return snapshot.downloads.isEmpty ? idleInterval : waitingInterval
    }

    // MARK: File watch

    // Sources stay open between watches; a new set of folders rebuilds them
    func watchFiles(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let folders = watchedFolders().map { $0.path(percentEncoded: false) }
        guard folders != watched else { return }
        watched = folders
        for source in sources { source.cancel() }
        sources = []
        for folder in folders { watch(folder) }
    }

    // Stop poking; the sources stay so the next watch has no setup race
    func quiet() {
        pending?.cancel()
        pending = nil
        onChange = nil
    }

    // The manifest folder of every library and the folder the logs are appended in
    func watchedFolders() -> [URL] {
        var folders = reader.files.libraries().map { $0.appending(path: "steamapps") }
        folders.append(reader.files.userData.appending(path: "logs"))
        return folders
    }

    private func watch(_ folder: String) {
        let fd = open(folder, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.emit() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    // A burst of writes lands as one poke, a beat after the first
    private func emit() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.fire()
        }
    }

    private func fire() {
        pending = nil
        onChange?()
    }
}

// The rate each download moved at over the last window of reads; paused and failed
// downloads hold no history so a resume starts clean.
struct RateTracker: Sendable {

    struct Sample: Equatable, Sendable {
        var at: Date
        var bytes: Int64
    }

    var span: TimeInterval = 20
    private var history: [Int: [Sample]] = [:]

    mutating func rates(for downloads: [DownloadActivity], now: Date) -> [Int: Int64] {
        let live = Set(downloads.map(\.appID))
        history = history.filter { live.contains($0.key) }
        var out: [Int: Int64] = [:]
        for item in downloads {
            guard item.state == .downloading else {
                history[item.appID] = nil
                out[item.appID] = 0
                continue
            }
            var samples = history[item.appID] ?? []
            if samples.last?.bytes != item.bytesDone {
                samples.append(Sample(at: now, bytes: item.bytesDone))
            }
            samples.removeAll { $0.at < now.addingTimeInterval(-span) }
            history[item.appID] = samples
            out[item.appID] = Self.rate(samples)
        }
        return out
    }

    static func rate(_ samples: [Sample]) -> Int64 {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else { return 0 }
        let dt = last.at.timeIntervalSince(first.at)
        guard dt > 0 else { return 0 }
        return max(0, Int64((Double(last.bytes - first.bytes) / dt).rounded()))
    }
}
