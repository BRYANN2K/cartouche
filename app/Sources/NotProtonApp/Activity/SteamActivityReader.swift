// Steam's downloads and its running game, read from Steam's own files:
// appmanifest_*.acf for the state flags and byte counts, logs/content_log.txt for
// pauses and failures the manifest does not carry yet, and gameprocess_log.txt,
// registry.vdf or the manifest's running bit for what runs. Sources: docs/research/p7-steam-downloads.md.

import Foundation

struct SteamActivitySnapshot: Equatable, Sendable {
    var downloads: [DownloadActivity] = []
    // Fully installed with nothing left to download
    var installed: Set<Int> = []
    var runningAppID: Int?
    // The processes Steam tracks for the running game, still alive
    var trackedPIDs: [pid_t] = []
    // Every app Steam has a manifest for, to name the running game
    var names: [Int: String] = [:]
}

struct SteamActivityReader: Sendable {

    // EAppState bits, as Steam writes them in StateFlags
    enum Flag {
        static let updateRequired = 2
        static let fullyInstalled = 4
        static let appRunning = 64
        static let updateRunning = 256
        static let updatePaused = 512
        static let updateStarted = 1024
        static let downloading = 1_048_576
    }

    var files = SteamLocalFiles()

    var contentLog: URL { files.userData.appending(path: "logs/content_log.txt") }
    var registry: URL { files.userData.appending(path: "registry.vdf") }
    var processLog: URL { files.userData.appending(path: "logs/gameprocess_log.txt") }

    func read() -> SteamActivitySnapshot {
        var snapshot = SteamActivitySnapshot()
        let log = Self.logStates(Self.tail(of: contentLog))
        for library in files.libraries() {
            let steamapps = library.appending(path: "steamapps")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path(percentEncoded: false))) ?? []
            for file in names where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let state = VDF.read(steamapps.appending(path: file))?["AppState"],
                      let appID = state["appid"]?.int, let name = state["name"]?.string,
                      !SteamLocalFiles.isTool(appID: appID, name: name)
                else { continue }
                snapshot.names[appID] = name
                let flags = state["StateFlags"]?.int ?? 0
                if flags & Flag.appRunning != 0 { snapshot.runningAppID = snapshot.runningAppID ?? appID }
                if let download = Self.download(appID: appID, name: name, state: state, log: log[appID]) {
                    // A stale copy of the manifest in a second library counts once
                    if !snapshot.downloads.contains(where: { $0.appID == appID }) { snapshot.downloads.append(download) }
                } else if flags & Flag.fullyInstalled != 0 {
                    snapshot.installed.insert(appID)
                }
            }
        }
        snapshot.downloads.sort { $0.appID < $1.appID }
        // Steam's own process tracking first, then what registry.vdf says, then the manifest bit
        let tracked = GameProcesses.tracked(inLog: Self.tail(of: processLog)).compactMapValues { pids -> [pid_t]? in
            let alive = pids.filter(GameProcesses.isAlive)
            return alive.isEmpty ? nil : alive
        }
        if let (appID, pids) = tracked.min(by: { $0.key < $1.key }) {
            snapshot.runningAppID = appID
            snapshot.trackedPIDs = pids
        } else if let running = runningFromRegistry() {
            snapshot.runningAppID = running
        }
        return snapshot
    }

    // A manifest that is being downloaded, queued or paused, or nil
    static func download(appID: Int, name: String, state: VDF, log: LogState?) -> DownloadActivity? {
        let flags = state["StateFlags"]?.int ?? 0
        let toDownload = Int64(state["BytesToDownload"]?.string ?? "") ?? 0
        let downloaded = Int64(state["BytesDownloaded"]?.string ?? "") ?? 0
        let toStage = Int64(state["BytesToStage"]?.string ?? "") ?? 0
        let staged = Int64(state["BytesStaged"]?.string ?? "") ?? 0
        let started = flags & (Flag.updateStarted | Flag.updateRunning | Flag.updatePaused | Flag.downloading) != 0
        let firstDownload = flags & Flag.updateRequired != 0 && flags & Flag.fullyInstalled == 0
        guard started || firstDownload else { return nil }
        // Downloading counts the network bytes; an update that only stages counts those
        let (done, total) = toDownload > 0 ? (downloaded, toDownload) : (staged, toStage)

        var item = DownloadActivity(appID: appID, name: name, state: .downloading, bytesDone: done, bytesTotal: total)
        let result = state["UpdateResult"]?.int ?? 0
        if flags & Flag.updatePaused != 0 {
            item.state = .paused
        } else if !started {
            item.state = .queued
        }
        if let log {
            switch log {
            case .paused: item.state = .paused
            case .failed(let reason): item.state = .failed(reason)
            case .running: if item.state == .paused || item.state == .queued { item.state = .downloading }
            }
        } else if result != 0, let reason = updateError(result) {
            item.state = .failed(reason)
        }
        return item
    }

    // EAppUpdateError, the ones a player can act on
    static func updateError(_ code: Int) -> String? {
        switch code {
        case 6: String(localized: "No internet connection")
        case 11: String(localized: "Disk write failure")
        case 12: String(localized: "Not enough disk space")
        case 16: String(localized: "Corrupt download")
        case 21: String(localized: "Content servers unreachable")
        default: String(localized: "Steam reported error \(code)")
        }
    }

    // MARK: content_log.txt

    enum LogState: Equatable, Sendable {
        case running
        case paused
        case failed(String)
    }

    // The last thing the log says about each app. Lines look like
    // [2026-10-19 21:04:11] AppID 1593500 update canceled : Suspended
    static func logStates(_ text: String) -> [Int: LogState] {
        var out: [Int: LogState] = [:]
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "AppID ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            guard let appID = Int(digits) else { continue }
            let event = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            if event.hasPrefix("update canceled :") {
                let reason = event.dropFirst("update canceled :".count).trimmingCharacters(in: .whitespaces)
                out[appID] = isPause(reason) ? .paused : .failed(reason.isEmpty ? String(localized: "Steam stopped the download") : reason)
            } else if event.hasPrefix("update started") || event.hasPrefix("update changed : Running")
                        || (event.hasPrefix("state changed :") && event.contains("Update Running")) {
                out[appID] = .running
            } else if event.hasPrefix("state changed :") && event.contains("Update Paused") {
                out[appID] = .paused
            } else if event.hasPrefix("finished update") || event.hasPrefix("fully installed")
                        || (event.hasPrefix("scheduler finished") && !event.contains("Suspended")) {
                out[appID] = nil
            } else if event.hasPrefix("scheduler finished") && event.contains("Suspended") {
                out[appID] = .paused
            }
        }
        return out
    }

    static func isPause(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.hasPrefix("suspended") || lower.contains("paused") || lower.contains("user request")
    }

    // The end of a log that Steam appends to for months
    static func tail(of url: URL, bytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: Running game

    // The new UI leaves RunningAppID at 0 on some systems, so 0 says nothing
    func runningFromRegistry() -> Int? {
        guard let id = VDF.read(registry)?[path: "Registry", "HKCU", "Software", "Valve", "Steam", "RunningAppID"]?.int,
              id > 0 else { return nil }
        return id
    }
}
