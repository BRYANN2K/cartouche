import Foundation
import RetroArchKit

enum SwitchArtwork {
    static func titleID(_ game: Game) -> String? {
        guard let console = game.console, console.console == "switch" else { return nil }
        let name = console.fileURL.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: "(?i)(?<![0-9a-f])010[0-9a-f]{13}(?![0-9a-f])", options: .regularExpression) else { return nil }
        return String(name[range]).uppercased()
    }

    static func displayName(_ game: ConsoleGame) -> String {
        guard game.console == "switch", game.name == game.fileURL.deletingPathExtension().lastPathComponent else { return game.name }
        let name = GameTitle.display(game.name)
        return name.isEmpty ? game.name : name
    }

    static func url(_ id: String, kind: ArtKind) -> URL {
        URL(string: "https://api.nlib.cc/nx/\(id)/\(kind == .cover ? "icon" : "banner/720p")")!
    }

    static func cached(_ id: String, kind: ArtKind, cache: URL) -> URL {
        cache.appending(path: "consoles/switch/\(id)/\(kind == .cover ? "icon" : "banner").jpg")
    }
}
