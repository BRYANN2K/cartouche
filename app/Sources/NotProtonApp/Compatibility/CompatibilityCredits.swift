// Source names and the data file's licenses stay as written there.

import Foundation

enum CompatibilityCredits {

    struct License: Equatable, Sendable {
        let source: String
        let license: String
        let url: String
        let attribution: String
    }

    static let macGamingDB = License(
        source: "MacGamingDB",
        license: String(localized: "No data license published"),
        url: "https://macgamingdb.app",
        attribution: String(localized: "Mac reports read live from MacGamingDB (macgamingdb.app) when you open a game. Cartouche keeps them on this Mac only and does not redistribute them.")
    )

    // MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL), AreWeAntiCheatYet (MIT)
    static func credits(_ data: CompatData?) -> [String] {
        [macGamingDB.source] + (data?.sources.all.map(\.credit) ?? ["ProtonDB (ODbL)"]) + ["Heroic MacAnticheatData (MIT)"]
    }

    static func sourcesLine(_ data: CompatData?) -> String {
        String(localized: "Sources: \(ListFormatter.localizedString(byJoining: credits(data)))")
    }
}
