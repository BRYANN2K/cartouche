// Names the sources next to their data, and lists their licenses.
// Source names and licenses come from the data file and stay as written there.

import Foundation

enum CompatibilityCredits {

    struct License: Equatable, Sendable {
        let source: String
        let license: String
        let url: String
        let attribution: String
    }

    // Read live by the app, so it is not among the data file's sources
    static let macGamingDB = License(
        source: "MacGamingDB",
        license: "No data license published",
        url: "https://macgamingdb.app",
        attribution: "Mac reports read live from MacGamingDB (macgamingdb.app) when you open a game. "
            + "Cartouche keeps them on this Mac only and does not redistribute them."
    )

    // MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL), AreWeAntiCheatYet (MIT)
    static func credits(_ data: CompatData?) -> [String] {
        [macGamingDB.source] + (data?.sources.all.map(\.credit) ?? [])
    }

    static func sourcesLine(_ data: CompatData?) -> String {
        String(localized: "Sources: \(ListFormatter.localizedString(byJoining: credits(data)))")
    }
}
