// What is going on right now: a running game, an install, Steam downloads and
// updates. The sidebar shows the most important one; the status menu lists them all.

import Foundation

struct RunningGame: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case steam(appID: Int)
        // A console session from RetroArch (P13), which quits through its own session
        case console
    }

    // The library's game ID, "steam:1245620"
    let id: String
    let name: String
    let target: Target
    // From the frame counter (P8); nil while nothing measures it
    var fps: Int?
    // RetroArch is still starting the game; Quit waits
    var starting = false
    // The standalone emulator a console game plays in (P16); nil for RetroArch
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

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var isPaused: Bool { state == .paused }
}

struct UpdateActivity: Identifiable, Equatable, Sendable {
    let id: String
    // "DXMT 0.80"
    let title: String
    // "Graphics", "Runner"
    let kind: String
}

enum ActivitySlot: Equatable, Sendable {
    case playing(RunningGame)
    case installing(InstallActivity)
    case downloads([DownloadActivity])
    case update(UpdateActivity)

    // Playing beats installing beats downloads beats updates; nil hides the slot
    static func pick(playing: RunningGame?, install: InstallActivity?,
                     downloads: [DownloadActivity], updates: [UpdateActivity]) -> ActivitySlot? {
        if let playing { return .playing(playing) }
        if let install { return .installing(install) }
        if !downloads.isEmpty { return .downloads(downloads) }
        if let update = updates.first { return .update(update) }
        return nil
    }
}

// The downloads as one ring: the average progress, and the worst state wins
struct DownloadSummary: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        // The stop square
        case downloading
        // Two bars
        case paused
        // An exclamation mark
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

    var percent: Int { Int((fraction * 100).rounded(.down)) }

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

    // "34% of 47.3 GB" for one game, "34%" for several
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

// Every ongoing activity, for the status item's menu
struct ActivityMenuSection: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case playing, installing, downloads, updates }

    struct Line: Equatable, Sendable {
        let title: String
        // Shown after the title, "34%"
        var detail: String?
    }

    let kind: Kind
    let lines: [Line]

    var header: String {
        switch kind {
        case .playing: String(localized: "Playing")
        case .installing: String(localized: "Installing")
        case .downloads: String(localized: "Downloads")
        case .updates: String(localized: "Updates")
        }
    }

    static func all(playing: RunningGame?, install: InstallActivity?,
                    downloads: [DownloadActivity], updates: [UpdateActivity]) -> [ActivityMenuSection] {
        var sections: [ActivityMenuSection] = []
        if let playing {
            sections.append(ActivityMenuSection(kind: .playing, lines: [Line(title: playing.name, detail: playing.fps.map { "\($0) fps" })]))
        }
        if let install {
            sections.append(ActivityMenuSection(kind: .installing, lines: [Line(title: install.title, detail: "\(Int(install.fraction * 100))%")]))
        }
        if !downloads.isEmpty {
            sections.append(ActivityMenuSection(kind: .downloads, lines: downloads.map {
                Line(title: $0.name, detail: Self.detail($0))
            }))
        }
        if !updates.isEmpty {
            sections.append(ActivityMenuSection(kind: .updates, lines: updates.map { Line(title: $0.title, detail: $0.kind) }))
        }
        return sections
    }

    static func detail(_ download: DownloadActivity) -> String {
        let percent = Int((download.fraction * 100).rounded(.down))
        switch download.state {
        case .failed: return String(localized: "Failed")
        case .paused: return String(localized: "Paused, \(percent)%")
        case .queued: return String(localized: "Waiting")
        case .downloading: return "\(percent)%"
        }
    }
}
