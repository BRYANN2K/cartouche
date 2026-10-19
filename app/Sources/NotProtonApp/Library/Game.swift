// One game in the library, PC or console, whatever store it comes from

import Foundation
import RetroArchKit

enum GameSource: Hashable, Sendable, Identifiable {
    case steam, epic, gog, amazon, installer
    // A console added through RetroArch, by its catalog id
    case console(String)

    static let pc: [GameSource] = [.steam, .epic, .gog, .amazon, .installer]

    var id: String {
        switch self {
        case .steam: "steam"
        case .epic: "epic"
        case .gog: "gog"
        case .amazon: "amazon"
        case .installer: "installer"
        case .console(let name): "console:\(name)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("console:") {
            self = .console(String(id.dropFirst("console:".count)))
            return
        }
        guard let pc = Self.pc.first(where: { $0.id == id }) else { return nil }
        self = pc
    }

    // Store and console names are product names, so not translated
    var name: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .gog: "GOG"
        case .amazon: "Amazon Games"
        case .installer: String(localized: "Windows Installers")
        case .console(let id): ConsoleCatalog.console(id)?.name ?? id
        }
    }

    var isConsole: Bool {
        if case .console = self { return true }
        return false
    }

    // Stores that need a sign-in before they list anything
    var isStore: Bool { self == .epic || self == .gog || self == .amazon }
}

enum CoverShape: Sendable {
    // PC box art, 600 by 900
    case portrait
    // Console boxes come in every shape, so they sit in a square
    case square

    var aspectRatio: CGFloat {
        switch self {
        case .portrait: 2.0 / 3.0
        case .square: 1
        }
    }
}

struct Game: Identifiable, Sendable, Equatable {
    var id: String
    var source: GameSource
    var name: String
    var steamAppID: Int?
    var installed: Bool
    var lastPlayed: Date?
    var playtimeMinutes: Int = 0
    var collections: [String] = []
    // The executable the cover drawn from the name carries, when one is known
    var executable: URL?
    // The RetroArch side of a console game
    var console: ConsoleGame?
    // Set for a Steam game that has a macOS build too: the version it runs
    var version: GameVersion?
    // A store game's box art, as its store lists it
    var artwork: URL?
    // The Steam App ID the compatibility data knows a store game by, matched by name,
    // for its estimate. Never used to start the game
    var compatAppID: Int?
    // For a Windows installer game: the setup its install ran with, used as the
    // default of its game setup until the user picks another one
    var installRunnerID: String?
    var installGraphics: GraphicsBackend?

    var coverShape: CoverShape { source.isConsole ? .square : .portrait }

    static func steam(_ appID: Int, name: String, installed: Bool) -> Game {
        Game(id: "steam:\(appID)", source: .steam, name: name, steamAppID: appID, installed: installed)
    }

    // "Windows version", "Played yesterday", "Not installed", "Installed"
    func status(now: Date = Date()) -> String {
        // An installed game with a Mac build says which version it runs, as the mockup does
        if let version, installed {
            return version == .windows ? String(localized: "Windows version") : String(localized: "Mac version")
        }
        if let lastPlayed {
            return String(localized: "Played \(GameDates.relative(lastPlayed, now: now))")
        }
        return installed ? String(localized: "Installed") : String(localized: "Not installed")
    }
}

enum GameDates {
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        // Within a day reads "today" rather than "in 3 hours" or "3 hours ago"
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return formatter.localizedString(from: DateComponents(day: -max(days, 1)))
    }
}
