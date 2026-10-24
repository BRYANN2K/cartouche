
import Foundation
import RetroArchKit

enum GameSource: Hashable, Sendable, Identifiable {
    case steam, epic, gog, amazon, installer
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

    var isStore: Bool { self == .epic || self == .gog || self == .amazon }
}

enum CoverShape: Sendable {
    case portrait
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
    var executable: URL?
    var console: ConsoleGame?
    // Set for a Steam game that has a macOS build too: the version it runs
    var version: GameVersion?
    var mediaHeader: URL?
    var mediaScreenshots: [URL]?
    var artwork: URL?
    // The Steam App ID the compatibility data knows a store game by, matched by name, for its estimate. Never used to start the game
    var compatAppID: Int?
    // For a Windows installer game: the setup its install ran with, used as the default of its game setup until the user picks another one
    var installRunnerID: String?
    var installGraphics: GraphicsBackend?
    var storageBytes: Int64? = nil
    var storageEstimated = false

    var coverShape: CoverShape { source.isConsole ? .square : .portrait }

    static func steam(_ appID: Int, name: String, installed: Bool) -> Game {
        Game(id: "steam:\(appID)", source: .steam, name: name, steamAppID: appID, installed: installed)
    }

    func status(now: Date = Date()) -> String {
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
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return formatter.localizedString(from: DateComponents(day: -max(days, 1)))
    }
}
