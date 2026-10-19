// What the console game panel shows, in order: can I play it, where do I
// continue from, how much did I play, with which setup. The rest is behind More….

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
    // RetroAchievements: the account, and this game's counts once read (P14)
    var signedIn = false
    var progress: AchievementProgress?
    // RetroArch, or the standalone emulator the console plays in (P16)
    var route: ConsoleRoute = .retroArch

    var biosMissing: Bool { bios.map { !$0.isReady } ?? false }

    // The BIOS warning comes right under Play, Continue From once a state exists
    var sections: [Section] {
        // States and the BIOS folder are RetroArch's; an emulator keeps its own
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

    // Under Play: "Dolphin is not installed", or the emulator that starts the game
    var playNote: String? {
        route.missingText ?? route.emulator.map { String(localized: "Plays in \($0.title)") }
    }

    // "Super Nintendo. Played yesterday."
    func subtitle(now: Date = Date()) -> String {
        let state = game.lastPlayed.map { String(localized: "Played \(GameDates.relative($0, now: now))") }
            ?? String(localized: "Never played")
        return String(localized: "\(console.name). \(state).")
    }

    var played: String {
        let minutes = Int(game.playSeconds / 60)
        if minutes < 1 { return game.playSeconds > 0 ? String(localized: "Under a minute") : String(localized: "Not yet") }
        if minutes < 60 { return minutes == 1 ? String(localized: "1 minute") : String(localized: "\(minutes) minutes") }
        let hours = game.playSeconds / 3600
        return String(localized: "\(hours.formatted(.number.precision(.fractionLength(0...1)))) hours")
    }

    // "12 of 64", as retroachievements.org counts them for the account
    var achievements: String {
        guard signedIn else { return String(localized: "Not signed in") }
        guard let progress else { return String(localized: "Not known yet") }
        guard progress.total > 0 else { return String(localized: "None for this game") }
        return String(localized: "\(progress.unlocked) of \(progress.total)")
    }

    // "scph5501.bin is missing", and what to do about it
    var biosWarning: (title: String, detail: String)? {
        guard biosMissing, let bios else { return nil }
        return (bios.message, String(localized: "Dump it from your own console, then put it in the BIOS folder."))
    }

    var cores: [(id: String, name: String)] { console.cores.map { ($0, ConsoleCatalog.coreName($0)) } }

    var core: String { game.setup.core ?? console.core }

    // "2 days ago" under each picture
    static func when(_ state: SaveState, now: Date = Date()) -> String {
        GameDates.relative(state.date, now: now)
    }
}
