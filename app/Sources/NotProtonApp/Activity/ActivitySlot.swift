
import Foundation

struct RunningGame: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case steam(appID: Int)
        case console
    }

    // The library's game ID, "steam:1245620"
    let id: String
    let name: String
    let target: Target
    var starting = false
    // The standalone emulator a console game plays in; nil for RetroArch
    var emulator: String?

    var onRetroArch: Bool { target == .console && emulator == nil }
}

struct DownloadActivity: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case downloading
        case paused
        case failed(String)
    }

    let appID: Int
    let name: String
    var state: State
    var bytesDone: Int64
    var bytesTotal: Int64

    var id: Int { appID }
    var gameID: String { "steam:\(appID)" }

    var fraction: Double {
        bytesTotal > 0 ? min(1, max(0, Double(bytesDone) / Double(bytesTotal))) : 0
    }

    var percent: Int { Int((fraction * 100).rounded(.down)) }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var isPaused: Bool { state == .paused }

    var title: String {
        switch state {
        case .failed: String(localized: "Download failed")
        case .paused: String(localized: "Paused")
        case .queued: String(localized: "Waiting to download")
        case .downloading: String(localized: "Downloading")
        }
    }

    var cardStatus: String {
        switch state {
        case .failed: return title
        case .paused: return String(localized: "Paused, \(percent)%")
        case .queued: return title
        case .downloading: return String(localized: "Downloading, \(percent)%")
        }
    }
}

enum ActivitySlot: Equatable, Sendable {
    case playing(RunningGame)
    case installing(InstallActivity)
    case store(StoreActivity)
    case downloads([DownloadActivity])

    static func pick(playing: RunningGame?, install: InstallActivity?, store: StoreActivity?,
                     downloads: [DownloadActivity]) -> ActivitySlot? {
        if let playing { return .playing(playing) }
        if let install { return .installing(install) }
        if let store { return .store(store) }
        if !downloads.isEmpty { return .downloads(downloads) }
        return nil
    }
}

struct DownloadSummary: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case downloading
        case paused
        case failed
    }

    let downloads: [DownloadActivity]

    var fraction: Double {
        downloads.isEmpty ? 0 : downloads.map(\.fraction).reduce(0, +) / Double(downloads.count)
    }

    var mark: Mark {
        if downloads.contains(where: \.isFailed) { return .failed }
        if !downloads.isEmpty && downloads.allSatisfy(\.isPaused) { return .paused }
        return .downloading
    }

    var percent: Int { Self.percent(of: fraction) }

    static func percent(of fraction: Double) -> Int { Int((fraction * 100).rounded(.down)) }

    var label: String {
        switch mark {
        case .failed: String(localized: "Download failed")
        case .paused: String(localized: "Paused")
        case .downloading:
            downloads.count > 1 ? String(localized: "Downloading \(downloads.count) games") : String(localized: "Downloading")
        }
    }

    var title: String {
        ListFormatter.localizedString(byJoining: downloads.map(\.name))
    }

    var detail: String {
        if downloads.count == 1, let only = downloads.first, only.bytesTotal > 0 {
            return String(localized: "\(percent)% of \(Self.size(only.bytesTotal))")
        }
        return "\(percent)%"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ActivityMenuSection: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case playing, installing, store, downloads }

    struct Line: Equatable, Sendable {
        let title: String
        var detail: String?
    }

    let kind: Kind
    let lines: [Line]

    var header: String {
        switch kind {
        case .playing: String(localized: "Playing")
        case .installing: String(localized: "Installing")
        case .store: String(localized: "Store")
        case .downloads: String(localized: "Downloads")
        }
    }

    static func all(playing: RunningGame?, install: InstallActivity?, store: StoreActivity?,
                    downloads: [DownloadActivity]) -> [ActivityMenuSection] {
        var sections: [ActivityMenuSection] = []
        if let playing {
            sections.append(ActivityMenuSection(kind: .playing, lines: [Line(title: playing.name)]))
        }
        if let install {
            sections.append(ActivityMenuSection(kind: .installing, lines: [Line(title: install.title, detail: "\(Int(install.fraction * 100))%")]))
        }
        if let store {
            sections.append(ActivityMenuSection(kind: .store, lines: [Line(title: store.title, detail: Self.detail(store))]))
        }
        if !downloads.isEmpty {
            sections.append(ActivityMenuSection(kind: .downloads, lines: downloads.map {
                Line(title: $0.name, detail: Self.detail($0))
            }))
        }
        return sections
    }

    static func detail(_ activity: StoreActivity) -> String {
        String(localized: "\(activity.label), \(DownloadSummary.percent(of: activity.fraction))%")
    }

    static func detail(_ download: DownloadActivity) -> String {
        switch download.state {
        case .failed: return String(localized: "Failed")
        case .paused: return String(localized: "Paused, \(download.percent)%")
        case .queued: return String(localized: "Waiting")
        case .downloading: return "\(download.percent)%"
        }
    }
}
