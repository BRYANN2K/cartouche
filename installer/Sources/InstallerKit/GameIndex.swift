
import Foundation

public struct GameIndex: Sendable {

    public struct Entry: Sendable, Equatable, Hashable {
        public let appID: Int
        public let name: String
        public init(appID: Int, name: String) { self.appID = appID; self.name = name }
    }

    private let byKey: [String: Entry]
    private let byID: [Int: Entry]
    private let tokenized: [(tokens: [String], entry: Entry)]

    public init(_ entries: [Entry]) {
        var byKey: [String: Entry] = [:]
        var byID: [Int: Entry] = [:]
        var tokenized: [([String], Entry)] = []
        // Lowest App ID first, so a name shared by a game and its later re-release keeps the original.
        for entry in entries.sorted(by: { $0.appID < $1.appID }) {
            if byID[entry.appID] == nil { byID[entry.appID] = entry }
            let tokens = Self.tokens(entry.name)
            guard !tokens.isEmpty else { continue }
            tokenized.append((tokens, entry))
            let key = tokens.joined(separator: " ")
            if byKey[key] == nil { byKey[key] = entry }
        }
        self.byKey = byKey
        self.byID = byID
        self.tokenized = tokenized
    }

    public var count: Int { tokenized.count }

    // "Baldur's Gate 3" and "baldurs gate III" give the same tokens.
    public static func tokens(_ name: String) -> [String] {
        var s = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "&", with: " and ")
        s.removeAll { "'’`™®©".contains($0) }
        let words = s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let roman = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]
        var out = words.map { roman[$0] ?? $0 }
        if out.first == "the", out.count > 1 { out.removeFirst() }
        return out
    }

    public static let noise: Set<String> = [
        "goty", "game", "of", "the", "year", "edition", "complete", "definitive", "deluxe", "ultimate",
        "enhanced", "remastered", "digital", "gold", "premium", "collectors", "directors", "anniversary",
        "special", "standard", "gog", "multi", "build", "offline", "installer", "dlc", "dlcs", "and", "all",
    ]

    public static func isNoise(_ token: String) -> Bool {
        noise.contains(token) || (try? /^(v|multi)\d+[a-z]?$/.wholeMatch(in: token)) != nil
    }

    public func entry(appID: Int) -> Entry? { byID[appID] }

    // Exact name, or longest known prefix when the rest is only edition words; bare numbers are not noise ("Portal 2" is not "Portal").
    public func match(_ query: String) -> Entry? {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return nil }
        if let exact = byKey[tokens.joined(separator: " ")] { return exact }
        for end in stride(from: tokens.count - 1, through: 1, by: -1) {
            guard tokens[end...].allSatisfy(Self.isNoise) else { break }
            if let found = byKey[tokens[..<end].joined(separator: " ")] { return found }
        }
        return nil
    }

    public func search(_ text: String, limit: Int = 20) -> [Entry] {
        let query = Self.tokens(text)
        guard !query.isEmpty else { return [] }
        let hits = tokenized.filter { item in
            query.allSatisfy { word in item.tokens.contains { $0.hasPrefix(word) } }
        }
        return hits
            .sorted { a, b in
                let ea = a.tokens == query, eb = b.tokens == query
                if ea != eb { return ea }
                if a.tokens.count != b.tokens.count { return a.tokens.count < b.tokens.count }
                return a.entry.name < b.entry.name
            }
            .prefix(limit)
            .map(\.entry)
    }
}

// goggame-<id>.info, written by GOG installers next to the game.
public struct GOGInfo: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let primaryExe: String?
    public let arguments: [String]
    public let workingDir: String?
    // A DLC's info points at the base game's id; saves use the Galaxy client id.
    public let rootID: String?
    public let clientID: String?

    public static func parse(_ data: Data) -> GOGInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = (json["gameId"] as? String) ?? (json["gameId"] as? Int).map(String.init)
        guard let id, !id.isEmpty else { return nil }
        let tasks = (json["playTasks"] as? [[String: Any]] ?? []).filter {
            (($0["category"] as? String).map { $0 == "game" } ?? true) && $0["type"] as? String != "URLTask"
        }
        let primary = tasks.first { ($0["isPrimary"] as? Bool) == true } ?? tasks.first
        return GOGInfo(
            id: id, name: json["name"] as? String,
            primaryExe: (primary?["path"] as? String)?.replacingOccurrences(of: "\\", with: "/"),
            arguments: (primary?["arguments"] as? String)?.split(separator: " ").map(String.init) ?? [],
            workingDir: primary?["workingDir"] as? String,
            rootID: json["rootGameId"] as? String,
            clientID: json["clientId"] as? String
        )
    }

    public static func primary(in folder: URL) -> (url: URL, info: GOGInfo)? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { isInfoName($0.lastPathComponent) }
        let infos = files.compactMap { url in (try? Data(contentsOf: url)).flatMap { parse($0).map { (url, $0) } } }
        if let root = infos.compactMap(\.1.rootID).first, let found = infos.first(where: { $0.1.id == root }) {
            return found
        }
        return infos.first
    }

    public static func find(in folder: URL) -> (url: URL, info: GOGInfo)? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let nested = top.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        for url in (top + nested).sorted(by: { $0.path < $1.path }) where isInfoName(url.lastPathComponent) {
            if let data = try? Data(contentsOf: url), let info = parse(data) { return (url, info) }
        }
        return nil
    }

    public static func id(inFileList files: [String]) -> String? {
        for file in files {
            let name = (file as NSString).lastPathComponent
            if let m = try? /(?i)^goggame-(\d+)\.info$/.wholeMatch(in: name) { return String(m.1) }
        }
        return nil
    }

    static func isInfoName(_ name: String) -> Bool {
        (try? /(?i)^goggame-\d+\.info$/.wholeMatch(in: name)) != nil
    }
}

public struct GameIdentification: Sendable, Equatable {
    public enum Source: String, Sendable {
        case gog, steamAppID, installerTitle, engineInfo, productName, exeName, folderName, user
    }

    public let name: String
    public let source: Source
    public let match: GameIndex.Entry?
    public let gogID: String?

    public init(name: String, source: Source, match: GameIndex.Entry?, gogID: String? = nil) {
        self.name = name; self.source = source; self.match = match; self.gogID = gogID
    }

    // First match wins in order: GOG info, a Steam app ID the folder carries, installer title, engine
    // metadata, exe product name, exe file name, the folder holding the exe, cleaned folder name.
    // With no match the best plain name is kept — the exe's or its folder's, never raw junk.
    public static func identify(
        gog: GOGInfo? = nil, gogID: String? = nil, steamAppID: Int? = nil,
        installerTitle: String? = nil, engineInfo: String? = nil, productName: String? = nil,
        exeName: String? = nil, innerFolder: String? = nil,
        folderName: String, index: GameIndex
    ) -> GameIdentification {
        let id = gog?.id ?? gogID
        let named = Self.orderedCandidates(gog: gog, installerTitle: installerTitle, engineInfo: engineInfo,
                                           productName: productName, exeName: exeName, innerFolder: innerFolder,
                                           folderName: folderName)
        if let entry = gog?.name.flatMap({ index.match($0) }) {
            return GameIdentification(name: entry.name, source: .gog, match: entry, gogID: id)
        }
        if let appID = steamAppID {
            let entry = index.entry(appID: appID)
            let title = entry?.name ?? best(named: named, folderName: folderName).1
            return GameIdentification(name: entry?.name ?? title, source: .steamAppID,
                                      match: entry ?? GameIndex.Entry(appID: appID, name: title), gogID: id)
        }
        for (source, name) in named {
            if let entry = index.match(name) { return GameIdentification(name: entry.name, source: source, match: entry, gogID: id) }
        }
        let (source, title) = best(named: named, folderName: folderName)
        return GameIdentification(name: title, source: id != nil ? .gog : source, match: nil, gogID: id)
    }

    // The name candidates in the order they are tried, so a store-search fallback asks about the
    // same names in the same order.
    public static func orderedCandidates(
        gog: GOGInfo? = nil, installerTitle: String? = nil, engineInfo: String? = nil,
        productName: String? = nil, exeName: String? = nil, innerFolder: String? = nil,
        folderName: String
    ) -> [(Source, String)] {
        [
            (.gog, gog?.name), (.installerTitle, installerTitle), (.engineInfo, engineInfo),
            (.productName, productName), (.exeName, exeName.map(GameName.clean)),
            (.folderName, innerFolder.map(GameName.clean)), (.folderName, GameName.clean(folderName)),
        ].compactMap { source, name in
            name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (source, $0) }
        }
    }

    // The title when nothing matched: installer/GOG names first, then the exe's or its folder's
    // cleaned name, the metadata names, and only the raw folder name when everything else failed.
    static func best(named: [(Source, String)], folderName: String) -> (Source, String) {
        for source in [Source.gog, .installerTitle, .exeName, .folderName, .productName, .engineInfo] {
            if let name = named.first(where: { $0.0 == source })?.1 { return (source, name) }
        }
        return (.folderName, folderName)
    }

    public func corrected(to entry: GameIndex.Entry) -> GameIdentification {
        GameIdentification(name: entry.name, source: .user, match: entry, gogID: gogID)
    }
}
