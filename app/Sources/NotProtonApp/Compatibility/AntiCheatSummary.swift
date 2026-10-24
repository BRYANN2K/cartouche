import Foundation

struct AntiCheatSummary: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case onlineWorks, onlineFails, untested, blocked
    }

    let level: Level
    let title: String
    let details: [String]
    var protonDBInfo: String? = nil
    var protonDBURL: URL? = nil

    func withProtonDB(_ entry: ProtonDBEntry?, appID: Int) -> Self {
        var result = self
        result.protonDBURL = URL(string: "https://www.protondb.com/app/\(appID)")
        if let entry, entry.onlineTried > 0,
           entry.onlinePlayed >= 0, entry.onlinePlayed <= entry.onlineTried {
            result.protonDBInfo = String(localized: "ProtonDB: \(entry.onlinePlayed)/\(entry.onlineTried) successful multiplayer reports (\(entry.fetched)).")
        } else {
            result.protonDBInfo = String(localized: "No multiplayer reports available from ProtonDB.")
        }
        return result
    }

    init(names: [String], blocked: Bool) {
        level = blocked ? .blocked : .untested
        title = blocked ? String(localized: "Anti-cheat is not compatible with Wine")
            : String(localized: "Anti-cheat compatibility is unverified")
        details = [ListFormatter.localizedString(byJoining: names),
            blocked ? String(localized: "Online modes requiring this anti-cheat are unavailable. Offline modes may still work.")
                : String(localized: "Online play has not been verified with Cartouche.")]
    }

    init?(record: CompatRecord?) {
        guard let entry = record?.areweanticheatyet else { return nil }
        // A positive Proton verdict does not establish support in Cartouche.
        let unsupported = entry.anticheats.contains { name in
            let name = name.lowercased().filter { $0.isLetter || $0.isNumber }
            return ["easyanticheat", "battleye", "eaanticheat", "vanguard", "faceit", "hyperion"].contains(name)
        }
        self.init(names: entry.anticheats, blocked: unsupported)
    }

    var lines: [String] { [title] + details }
}

enum ProtonDBCatalog {
    static let entries: [String: ProtonDBEntry] = {
        guard let url = Bundle.module.url(forResource: "protondb-online", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: ProtonDBEntry].self, from: data) else { return [:] }
        return entries
    }()

    static func entry(appID: Int, current: ProtonDBEntry?) -> ProtonDBEntry? {
        guard let bundled = entries[String(appID)] else { return current }
        guard let current, current.fetched >= bundled.fetched else { return bundled }
        return current
    }
}

// Heroic's Mac-specific interpretation of AreWeAntiCheatYet, distributed under MIT.
// The snapshot remains usable when the separate compatibility release is unavailable.
enum MacAntiCheatCatalog {
    struct Entry: Decodable {
        let status: String
        let anticheats: [String]
    }
    static let entries: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "mac-anticheat", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }()
    static func summary(appID: Int) -> AntiCheatSummary? {
        guard let entry = entries[String(appID)] else { return nil }
        return AntiCheatSummary(names: entry.anticheats, blocked: ["Denied", "Broken"].contains(entry.status))
    }
}
