// Game titles to the compatibility data's Steam App IDs: the name index is built
// once per data file, shared by the install sheet and the store sign-in, and a
// rebuild runs off the main actor.

import Foundation
import InstallerKit

@MainActor
final class TitleIndex {
    private var index: GameIndex?
    private var built: Int?

    // The shared index: rebuilt only when the compat data changes.
    func index(for data: CompatData?) async -> GameIndex {
        guard let data else { return GameIndex([]) }
        if let index, built == data.records.count { return index }
        let builtIndex = await Task.detached { GameIndex(compat: data) }.value
        index = builtIndex
        built = data.records.count
        return builtIndex
    }

    func appID(_ title: String, data: CompatData?) -> Int? {
        guard let data else { return nil }
        if index == nil || built != data.records.count {
            index = GameIndex(compat: data)
            built = data.records.count
        }
        return index?.match(title)?.appID
    }
}
