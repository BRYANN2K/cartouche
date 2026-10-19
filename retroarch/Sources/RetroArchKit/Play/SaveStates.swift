import Foundation

// A save state RetroArch wrote for a game, with the picture it saves beside it
public struct SaveState: Sendable, Equatable, Identifiable {
    // nil for the auto state written on quit
    public var slot: Int?
    public var file: URL
    public var picture: URL?
    public var date: Date

    public var id: String { file.path(percentEncoded: false) }

    public var isAuto: Bool { slot == nil }

    public var title: String {
        guard let slot else { return String(localized: "Auto", bundle: .module) }
        return String(localized: "Slot \(slot)", bundle: .module)
    }
}

// The states of one game in Cartouche's states folder. RetroArch names them
// after the loaded file: name.state, name.state1 …, name.state.auto, with
// name.state1.png for the picture, in a folder per core.
public enum SaveStates {

    public static func list(for game: ConsoleGame, in paths: RetroArchPaths) -> [SaveState] {
        list(contentName: game.contentName, in: paths.states)
    }

    public static func list(contentName: String, in folder: URL) -> [SaveState] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        var states: [SaveState] = []
        while let file = walker?.nextObject() as? URL {
            let name = file.lastPathComponent
            guard name.hasPrefix(contentName + ".state") else { continue }
            let suffix = name.dropFirst(contentName.count + ".state".count)
            let slot: Int?
            if suffix == ".auto" {
                slot = nil
            } else if suffix.isEmpty {
                slot = 0
            } else if let n = Int(suffix), n > 0 {
                slot = n
            } else {
                continue
            }
            let picture = file.appendingPathExtension("png")
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            states.append(SaveState(
                slot: slot, file: file,
                picture: FileManager.default.fileExists(atPath: picture.path(percentEncoded: false)) ? picture : nil,
                date: date))
        }
        // Auto first, then the most recent
        return states.sorted { a, b in
            if a.isAuto != b.isAuto { return a.isAuto }
            return a.date > b.date
        }
    }
}
