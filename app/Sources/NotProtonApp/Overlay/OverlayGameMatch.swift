import Foundation

// The library's game for a running Wine process: Steam's app ID, the exe's folder, the game Cartouche
// launched, then the name without « .exe »
enum OverlayGameMatch {
    static func match(name: String, appID: Int?, exe: String?, playingID: String?, games: [Game], folder: (Game) -> URL?) -> Game? {
        if let appID, let game = games.first(where: { $0.steamAppID == appID }) { return game }
        if let exe {
            let path = URL(filePath: exe).standardizedFileURL.path(percentEncoded: false)
            if let game = games.first(where: { game in
                guard let root = folder(game)?.standardizedFileURL.path(percentEncoded: false) else { return false }
                return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }) { return game }
        }
        if let playingID, let game = games.first(where: { $0.id == playingID }) { return game }
        let wanted = key(name)
        return wanted.isEmpty ? nil : games.first { key($0.name) == wanted }
    }

    static func displayName(_ name: String) -> String {
        name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    // « deadlock.exe », « Deadlock » and « DEADLOCK » read the same
    static func key(_ name: String) -> String {
        String(displayName(name).lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func steamAppID(_ environment: [String: String]) -> Int? {
        (environment["SteamAppId"] ?? environment["SteamGameId"] ?? environment["STEAM_COMPAT_APP_ID"]).flatMap(Int.init)
    }
}
