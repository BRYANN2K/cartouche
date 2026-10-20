
import Foundation

struct GameSetupChoice: Codable, Equatable, Sendable {
    var runnerID: String?
    var graphics: GraphicsBackend?
    var translation: Translation?
    var metalHUD: Bool?
    var version: GameVersion?
    var environment: [String: String]?

    enum Translation: String, Codable, Sendable, CaseIterable {
        case rosetta, fex

        var label: String {
            switch self {
            case .rosetta: "Rosetta"
            case .fex: "FEX"
            }
        }
    }
}

enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case d3dmetal, dxmt, dxvk, wined3d

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "wined3d"
        }
    }

    init?(_ layer: TranslationLayer) {
        switch layer {
        case .d3dmetal: self = .d3dmetal
        case .dxmt: self = .dxmt
        case .dxvk: self = .dxvk
        }
    }
}

struct LibraryChoices: Codable, Equatable, Sendable {
    var favorites: Set<String> = []
    var hidden: Set<String> = []
    var covers: [String: String] = [:]
    var setups: [String: GameSetupChoice] = [:]
}

struct LibraryStore: Sendable {

    var folder: URL = SupportPaths.support

    var file: URL { folder.appending(path: "library.json") }
    var coverFolder: URL { folder.appending(path: "covers") }

    func load() -> LibraryChoices {
        guard let data = try? Data(contentsOf: file),
              let choices = try? JSONDecoder().decode(LibraryChoices.self, from: data)
        else { return LibraryChoices() }
        return choices
    }

    func save(_ choices: LibraryChoices) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try atomicReplace(file, with: try encoder.encode(choices), step: "library")
    }

    func keepCover(_ image: URL, for gameID: String) throws -> String {
        try FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        let safe = gameID.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let ext = image.pathExtension.isEmpty ? "png" : image.pathExtension.lowercased()
        let name = "\(safe)-\(UUID().uuidString.prefix(8)).\(ext)"
        try FileManager.default.copyItem(at: image, to: coverFolder.appending(path: name))
        return name
    }

    func coverURL(_ name: String) -> URL { coverFolder.appending(path: name) }

    func deleteCover(_ name: String) {
        try? FileManager.default.removeItem(at: coverURL(name))
    }
}
