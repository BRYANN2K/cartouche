import Foundation
import RetroArchKit

struct ConsolePanelContent {

    enum Section: String, Sendable {
        case play, bios, continueFrom, stats, setup, controls, playTogether, more

        var title: String {
            switch self {
            case .play: String(localized: "Play")
            case .bios: "BIOS"
            case .continueFrom: String(localized: "Continue From")
            case .stats: String(localized: "Your Play")
            case .setup: String(localized: "Setup")
            case .controls: String(localized: "Controls")
            case .playTogether: String(localized: "Play Together")
            case .more: String(localized: "More…")
            }
        }
    }

    let game: ConsoleGame
    let console: Console
    let states: [SaveState]
    let bios: BIOSStatus?
    let playing: Playing?
    var signedIn = false
    var progress: AchievementProgress?
    var route: ConsoleRoute = .retroArch

    var biosMissing: Bool { bios.map { !$0.isReady } ?? false }

    var sections: [Section] {
        guard route == .retroArch else { return [.play, .stats, .setup, .controls, .more] }
        var out: [Section] = [.play]
        if biosMissing { out.append(.bios) }
        if !states.isEmpty { out.append(.continueFrom) }
        out += [.stats, .setup, .controls, .playTogether, .more]
        return out
    }

    // Hardcore forbids states: Continue From and Resume wait until it is off
    var statesAllowed: Bool { !game.setup.hardcore }

    var titles: [String] { sections.map { $0 == .play ? playLabel : $0.title } }

    var hasAutoState: Bool { states.contains(where: \.isAuto) }

    var playLabel: String {
        switch playing?.phase {
        case .starting: String(localized: "Starting…")
        case .playing: String(localized: "Playing")
        case nil: hasAutoState && route == .retroArch && statesAllowed ? String(localized: "Resume") : String(localized: "Play")
        }
    }

    var canPlay: Bool {
        guard route == .retroArch else { return playing == nil && route.emulator != nil && game.exists }
        return playing == nil && !biosMissing && game.exists
    }

    var playNote: String? {
        route.missingText ?? route.emulator.map { String(localized: "Plays in \($0.title)") }
    }

    // The newest proof the game ran: a counted session or a save state on disk.
    // The subtitle, the Played row and the Play/Resume button all read it, so they agree.
    var playedAt: Date? {
        [game.lastPlayed, states.map(\.date).max()].compactMap { $0 }.max()
    }

    func subtitle(now: Date = Date()) -> String {
        let state = playedAt.map { String(localized: "Played \(GameDates.relative($0, now: now))") }
            ?? String(localized: "Never played")
        return String(localized: "\(console.name). \(state).")
    }

    var played: String {
        let minutes = Int(game.playSeconds / 60)
        if minutes < 1 {
            if game.playSeconds > 0 { return String(localized: "Under a minute") }
            if let playedAt { return GameDates.relative(playedAt, now: Date()) }
            return String(localized: "Not yet")
        }
        if minutes < 60 { return minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes") }
        let hours = game.playSeconds / 3600
        return String(localized: "\(hours.formatted(.number.precision(.fractionLength(0...1)))) hours")
    }

    var achievements: String {
        guard signedIn else { return String(localized: "Not signed in") }
        guard let progress else { return String(localized: "Not known yet") }
        guard progress.total > 0 else { return String(localized: "None for this game") }
        return String(localized: "\(progress.unlocked) of \(progress.total)")
    }

    var biosWarning: (title: String, detail: String)? {
        guard biosMissing, let bios else { return nil }
        return (bios.message, String(localized: "Dump it from your own console, then put it in the BIOS folder."))
    }

    var cores: [(id: String, name: String)] { console.cores.map { ($0, ConsoleCatalog.coreName($0)) } }

    var core: String { game.setup.core ?? console.core }

    static func when(_ state: SaveState, now: Date = Date()) -> String {
        GameDates.relative(state.date, now: now)
    }
}
