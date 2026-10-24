
import Foundation
import InstallerKit

@MainActor
final class TitleIndex {
    private var index: GameIndex?
    private var built: Int?

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
