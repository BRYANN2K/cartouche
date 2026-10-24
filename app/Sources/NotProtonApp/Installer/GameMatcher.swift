
import Foundation
import InstallerKit

extension GameIndex {

    init(compat: CompatData?) {
        let entries = (compat?.records ?? [:]).compactMap { key, record in
            Int(key).map { GameIndex.Entry(appID: $0, name: record.name) }
        }
        self.init(entries)
    }
}

enum GameCover {

    // Steam's portrait library art, the same image the library grid shows.
    static func steam(appID: Int) -> URL? {
        URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900.jpg").map(QAEnvironment.url)
    }
}
