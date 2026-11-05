import Foundation

// One JSON profile and one notes file per game, in Application Support/Cartouche/Overlay
struct OverlayProfileStore: Sendable {
    var folder: URL

    static var standard: OverlayProfileStore {
        OverlayProfileStore(folder: SupportPaths.support.appending(path: "Overlay", directoryHint: .isDirectory))
    }

    private func file(_ game: String, _ suffix: String) -> URL {
        let safe = game.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return folder.appending(path: String(safe) + suffix)
    }

    func profile(for game: String) -> OverlaySettings? {
        guard let data = try? Data(contentsOf: file(game, ".json")) else { return nil }
        return try? JSONDecoder().decode(OverlaySettings.self, from: data)
    }

    func save(_ settings: OverlaySettings, for game: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file(game, ".json"), options: .atomic)
    }

    func notes(for game: String) -> String {
        (try? String(contentsOf: file(game, ".notes.txt"), encoding: .utf8)) ?? ""
    }

    func saveNotes(_ text: String, for game: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file(game, ".notes.txt"), atomically: true, encoding: .utf8)
    }
}

// The profile being edited against the one on disk
struct OverlayProfile: Equatable, Sendable {
    var saved: OverlaySettings
    var current: OverlaySettings

    init(saved: OverlaySettings) {
        self.saved = saved
        current = saved
    }

    var isModified: Bool { current != saved }

    mutating func markSaved() { saved = current }
}
