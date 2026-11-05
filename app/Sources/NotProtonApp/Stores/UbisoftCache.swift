// Ubisoft Connect's local caches, read out of the launcher's prefix after the user has
// signed in there: ownership/<account id> is protobuf (one OwnedGame per product) and
// configuration/configurations is protobuf whose `configuration` strings are YAML
// product cards (name, art file names, localized names). Field numbers follow UplayDB's
// dumped proto2 schemas; the YAML keys are the ones launchers read. Fixtures cover this
// in tests — exact enum values (platform, product_type, state) stay unverified without
// a signed-in prefix.

import Foundation
import InstallerKit

// Minimal proto2 wire reading: varints, fixed widths and length-delimited chunks.
struct ProtobufMessage: Sendable {
    struct Field: Sendable {
        let number: Int
        let varint: UInt64?
        let bytes: Data?
    }
    let fields: [Field]

    enum ReadError: Error { case truncated, unsupported }

    init(_ data: Data) throws {
        var fields: [Field] = []
        var i = data.startIndex
        func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let byte = data[i]; i += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                guard shift < 70 else { throw ReadError.truncated }
            }
            throw ReadError.truncated
        }
        while i < data.endIndex {
            let tag = try varint()
            let number = Int(tag >> 3)
            switch Int(tag & 7) {
            case 0:
                fields.append(Field(number: number, varint: try varint(), bytes: nil))
            case 1:
                guard i + 8 <= data.endIndex else { throw ReadError.truncated }
                var v: UInt64 = 0
                for b in 0..<8 { v |= UInt64(data[i + b]) << UInt64(8 * b) }
                i += 8
                fields.append(Field(number: number, varint: v, bytes: nil))
            case 2:
                guard let count = Int(exactly: try varint()), count <= data.endIndex - i else { throw ReadError.truncated }
                fields.append(Field(number: number, varint: nil, bytes: Data(data[i..<i + count])))
                i += count
            case 5:
                guard i + 4 <= data.endIndex else { throw ReadError.truncated }
                var v: UInt64 = 0
                for b in 0..<4 { v |= UInt64(data[i + b]) << UInt64(8 * b) }
                i += 4
                fields.append(Field(number: number, varint: v, bytes: nil))
            default:
                throw ReadError.unsupported
            }
        }
        self.fields = fields
    }

    // Varint fields, plus packed lists decoded the same way.
    func ints(_ number: Int) -> [UInt64] {
        fields.filter { $0.number == number }.flatMap { field -> [UInt64] in
            if let varint = field.varint { return [varint] }
            var out: [UInt64] = []
            if let bytes = field.bytes {
                var i = bytes.startIndex
                while i < bytes.endIndex {
                    var value: UInt64 = 0, shift: UInt64 = 0
                    while i < bytes.endIndex {
                        let byte = bytes[i]; i += 1
                        value |= UInt64(byte & 0x7f) << shift
                        if byte & 0x80 == 0 { break }
                        shift += 7
                        guard shift < 70 else { return out }
                    }
                    out.append(value)
                }
            }
            return out
        }
    }

    func int(_ number: Int) -> UInt64? { ints(number).first }
    func string(_ number: Int) -> String? {
        fields.last { $0.number == number }?.bytes.flatMap { String(data: $0, encoding: .utf8) }
    }
    func messages(_ number: Int) -> [ProtobufMessage] {
        fields.filter { $0.number == number }.compactMap(\.bytes).compactMap { try? ProtobufMessage($0) }
    }
}

// Only the nested maps of scalars a product card needs; lists and block scalars are skipped.
enum UbisoftYAML {
    typealias Map = [String: Any]

    static func map(_ text: String) -> Map {
        var lines = text.components(separatedBy: .newlines)
        var index = lines.startIndex
        return parse(&lines, &index, indent: 0, depth: 0)
    }

    static func string(_ map: Map, _ path: String...) -> String? {
        var node: Any? = map
        for key in path {
            guard let branch = node as? Map else { return nil }
            node = branch[key]
        }
        return node as? String
    }

    static func strings(_ map: Map, _ path: String...) -> [String: String]? {
        var node: Any? = map
        for key in path {
            guard let branch = node as? Map else { return nil }
            node = branch[key]
        }
        return (node as? Map)?.compactMapValues { $0 as? String }
    }

    private static func parse(_ lines: inout [String], _ index: inout Int, indent: Int, depth: Int) -> Map {
        var map: Map = [:]
        while index < lines.endIndex {
            let line = lines[index].replacingOccurrences(of: "\r", with: "")
            let body = line.replacingOccurrences(of: "\t", with: "  ")
            let level = body.prefix(while: { $0 == " " }).count
            let content = stripComment(body).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty && content != "---" && content != "..." else { index += 1; continue }
            guard level >= indent else { break }
            guard !content.hasPrefix("-"), let colon = splitPoint(content) else { index += 1; continue }
            let key = unquote(String(content[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty || rest.hasPrefix("|") || rest.hasPrefix(">") {
                if depth < 64 {
                    let child = parse(&lines, &index, indent: level + 1, depth: depth + 1)
                    if rest.isEmpty { map[key] = child }
                } else {
                    // Past the depth bound: eat the nested lines without nesting further
                    while index < lines.endIndex {
                        let body = lines[index].replacingOccurrences(of: "\t", with: "  ")
                        guard body.prefix(while: { $0 == " " }).count > level else { break }
                        index += 1
                    }
                }
            } else {
                map[key] = unquote(rest)
            }
        }
        return map
    }

    private static func splitPoint(_ body: String) -> String.Index? {
        var it = body.startIndex
        while it < body.endIndex {
            if body[it] == ":", (body.index(after: it) == body.endIndex || body[body.index(after: it)] == " ") { return it }
            it = body.index(after: it)
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var quoted: Character? = nil
        var it = line.startIndex
        while it < line.endIndex {
            let c = line[it]
            if c == "\"" || c == "'" { quoted = quoted == c ? nil : (quoted == nil ? c : quoted) }
            if c == "#", quoted == nil, it > line.startIndex, line[line.index(before: it)] == " " {
                return String(line[..<it])
            }
            it = line.index(after: it)
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last, first == last, first == "\"" || first == "'"
        else { return s }
        return String(s.dropFirst().dropLast())
    }
}

// One owned product, as ownership_cache.proto's OwnedGame carries it — or as the
// launcher's cached entitlements body reports it when the .vdat caches are sealed.
struct UbisoftOwned: Sendable, Equatable {
    var productID: Int     // field 1 — the install/uninstall id of registry Installs\<id>
    var uplayID: Int?      // field 2 — the launch id of uplay://launch/<id>/0
    var gameCode: String?  // field 10
    var platform: Int?     // field 5
    var productType: Int?  // field 6
    var state: Int?        // field 7
    var activation: Int?   // field 18
    var spaceID: String?   // entitlements only — the space editions of one title share

    init(productID: Int, spaceID: String? = nil) {
        self.productID = productID
        self.spaceID = spaceID
    }

    init?(_ message: ProtobufMessage) {
        guard let id = message.int(1), let productID = Int(exactly: id) else { return nil }
        self.productID = productID
        uplayID = message.int(2).flatMap(Int.init(exactly:))
        platform = message.int(5).flatMap(Int.init(exactly:))
        productType = message.int(6).flatMap(Int.init(exactly:))
        state = message.int(7).flatMap(Int.init(exactly:))
        gameCode = message.string(10)
        activation = message.int(18).flatMap(Int.init(exactly:))
    }
}

// A product card from configuration.proto: name, art file names, localized names.
struct UbisoftConfig: Sendable, Equatable {
    var productID: Int
    var uplayID: Int
    var name: String
    var localizedName: String?
    var artName: String?
    var headerName: String?

    // The CDN the launcher pulls its art from; the file names are the cache's own.
    static let artBase = "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/"

    var title: String { localizedName ?? name }
    var art: URL? { artName.flatMap { URL(string: Self.artBase + $0) } }
    var header: URL? { headerName.flatMap { URL(string: Self.artBase + $0) } }
}

// A space's card from the launcher's cached bodies: the name the entitlements
// list cannot carry, the portrait box-art candidate for the card and the wide
// art for the panel.
struct UbisoftSpace: Sendable, Equatable {
    var name: String?
    var art: URL?
    var header: URL?
}

struct UbisoftCache: Sendable, Equatable {
    var userID: String? = nil
    var ownershipModified: Date? = nil
    var owned: [UbisoftOwned] = []
    var visibleIDs: Set<Int> = []
    var configs: [Int: UbisoftConfig] = [:]
    var titles: [String: String] = [:]        // spaceId -> catalog title, from the cached store index
    var spaces: [String: UbisoftSpace] = [:]  // spaceId -> name + images, from cached games/api and products bodies
}

enum UbisoftLocalCache {

    // A cache file past this size is skipped like a missing one — a malformed or
    // hostile write must never make the whole app parse it.
    static let fileLimit = 64 * 1024 * 1024

    // The current launcher's cache files end in .vdat: a protobuf envelope whose
    // versioned header (key id, 12-byte nonce, 16-byte tag) precedes a sealed body.
    // There is nothing readable inside without the launcher's own key — the session
    // still counts, the game list stays empty rather than decoding header bytes as
    // games.
    static let sealedSuffix = ".vdat"

    // The account id is the file's base name — the .vdat the launcher appends is not
    // part of it and must never reach the screen.
    static func account(_ file: String) -> String {
        file.hasSuffix(sealedSuffix) ? String(file.dropLast(sealedSuffix.count)) : file
    }

    // The active session's file inside one cache/ownership dir: the file the launcher
    // rewrote last — never the first name, several accounts can coexist.
    static func activeOwnershipFile(in ownershipDir: URL) -> String? {
        let fm = FileManager.default
        let owners = ((try? fm.contentsOfDirectory(atPath: ownershipDir.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }
        func modified(_ name: String) -> Date {
            (try? fm.attributesOfItem(atPath: ownershipDir.appending(path: name).path(percentEncoded: false)))?[.modificationDate] as? Date ?? .distantPast
        }
        return owners.max { a, b in (modified(a), a) < (modified(b), b) }
    }

    // The account the launcher last signed in as, without parsing the cache — what the
    // sign-in watcher polls while the user types inside the launcher.
    static func userID(prefix: URL) -> String? {
        for root in roots(prefix: prefix) {
            if let file = activeOwnershipFile(in: root.appending(path: "ownership")) { return account(file) }
        }
        return nil
    }

    // Sign-out: the account's ownership file goes in every cache root, so the next poll
    // does not silently adopt the same session back.
    static func forget(prefix: URL, account: String) {
        for root in roots(prefix: prefix) {
            let dir = root.appending(path: "ownership")
            try? FileManager.default.removeItem(at: dir.appending(path: account))
            try? FileManager.default.removeItem(at: dir.appending(path: account + sealedSuffix))
        }
    }

    static func read(prefix: URL) throws -> UbisoftCache {
        let fm = FileManager.default
        for root in roots(prefix: prefix) {
            let ownershipDir = root.appending(path: "ownership")
            guard let file = activeOwnershipFile(in: ownershipDir) else { continue }
            var cache = UbisoftCache(userID: account(file))
            let ownership = ownershipDir.appending(path: file)
            cache.ownershipModified = (try? fm.attributesOfItem(atPath: ownership.path(percentEncoded: false)))?[.modificationDate] as? Date
            if let data = contents(of: file, at: ownership), let message = try? ProtobufMessage(data) {
                cache.owned = owned(message)
                cache.visibleIDs = Set(message.ints(3).compactMap(Int.init(exactly:)))
            }
            let configurationDir = root.appending(path: "configuration")
            if let name = ["configurations.vdat", "configurations"].first(where: {
                    fm.fileExists(atPath: configurationDir.appending(path: $0).path(percentEncoded: false)) }),
               let data = contents(of: name, at: configurationDir.appending(path: name)),
               let message = try? ProtobufMessage(data) {
                cache.configs = configurations(message)
            }
            // Sealed caches leave the owned list empty; the launcher's own HTTP cache
            // still holds the entitlements, store-index and games/api bodies it fetched.
            if cache.owned.isEmpty {
                let http = httpBodies(in: root)
                cache.owned = http.owned
                if !http.owned.isEmpty { cache.visibleIDs = Set(http.owned.map(\.productID)) }
                cache.titles = http.titles
                cache.spaces = http.spaces
            }
            return cache
        }
        throw StoreError.notSignedIn
    }

    // Sealed files yield nothing; older launchers wrote the bare protobuf.
    private static func contents(of file: String, at url: URL) -> Data? {
        file.hasSuffix(sealedSuffix) ? nil : readCapped(url)
    }

    // The plaintext API bodies the launcher's own CEF profile already fetched —
    // the entitlements list (accessLevel "owned" is the account's), the store
    // index (spaceId -> title), the games/api cards and the GraphQL products
    // bodies (spaceId -> name + images). Cache entries prepend request metadata,
    // so each body starts at its marker, not at byte 0.
    static func httpBodies(in root: URL) -> (owned: [UbisoftOwned], titles: [String: String], spaces: [String: UbisoftSpace]) {
        guard let files = FileManager.default.enumerator(at: root.appending(path: "http2"),
                                                         includingPropertiesForKeys: nil) else { return ([], [:], [:]) }
        var owned: [UbisoftOwned] = []
        var titles: [String: String] = [:]
        var spaces: [String: UbisoftSpace] = [:]
        let marker = Data(#"{"entitlements""#.utf8)
        let index = Data(#"{"hits""#.utf8)
        let card = Data(#"{"spaceId""#.utf8)
        let cards = Data(#"{"games""#.utf8)
        let product = Data(#"{"productId""#.utf8)
        for case let file as URL in files {
            guard let data = readCapped(file) else { continue }
            for span in spans(of: marker, in: data) {
                guard let list = dict(at: span, in: data)?["entitlements"] as? [[String: Any]] else { continue }
                let parsed = list.compactMap { item -> UbisoftOwned? in
                    guard item["accessLevel"] as? String == "owned", item["type"] as? String == "game",
                          let id = (item["productId"] as? NSNumber)?.intValue else { return nil }
                    return UbisoftOwned(productID: id, spaceID: item["spaceId"] as? String)
                }
                if parsed.count > owned.count { owned = parsed }
            }
            for span in spans(of: index, in: data) {
                guard let hits = dict(at: span, in: data)?["hits"] as? [[String: Any]] else { continue }
                for hit in hits {
                    guard let title = hit["title"] as? String else { continue }
                    for availability in hit["availabilities"] as? [[String: Any]] ?? [] {
                        if let space = availability["spaceId"] as? String { titles[space] = title }
                    }
                }
            }
            // A space's body answers alone, under a games array, or as a products
            // entry — each carries the same name/art fields at its top level
            for span in spans(of: card, in: data) + spans(of: cards, in: data) + spans(of: product, in: data) {
                guard let body = dict(at: span, in: data) else { continue }
                for item in body["games"] as? [[String: Any]] ?? [] { space(item, into: &spaces) }
                space(body, into: &spaces)
            }
        }
        return (owned, titles, spaces)
    }

    // One space's body — games/api card, `games` item or products entry. `art` keeps
    // only the box-art keys (the real cover candidates); the wide thumbnails and
    // backgrounds go to `header` for the panel. A body that adds none is skipped.
    private static func space(_ body: [String: Any], into spaces: inout [String: UbisoftSpace]) {
        guard let id = body["spaceId"] as? String else { return }
        let urls = body["imageUrls"] as? [String: Any] ?? [:]
        func url(_ key: String) -> URL? { (urls[key] as? String).flatMap(Self.httpURL) }
        func field(_ key: String) -> URL? { (body[key] as? String).flatMap(Self.httpURL) }
        let space = UbisoftSpace(name: body["displayName"] as? String ?? body["name"] as? String,
                                 art: url("highBoxArt") ?? url("lowBoxArt") ?? field("highBoxArtUrl") ?? field("lowBoxArtUrl") ?? field("image"),
                                 header: url("background") ?? field("backgroundUrl") ?? field("coverImage") ?? url("highThumbnail"))
        guard space.name != nil || space.art != nil || space.header != nil else { return }
        spaces[id] = UbisoftSpace(name: space.name ?? spaces[id]?.name,
                                  art: space.art ?? spaces[id]?.art,
                                  header: space.header ?? spaces[id]?.header)
    }

    // Cache bodies are untrusted: only an http(s) string may become a remote.
    static func httpURL(_ string: String) -> URL? {
        string.hasPrefix("http") ? URL(string: string) : nil
    }

    // Where a marker's JSON object ends: braces balance outside quoted strings.
    private static func span(of marker: Data, in data: Data, from start: Int) -> Range<Int>? {
        guard let start = data.range(of: marker, in: start..<data.endIndex)?.lowerBound else { return nil }
        var i = start, depth = 0, quoted = false, escaped = false
        while i < data.endIndex {
            let byte = data[i]
            if escaped { escaped = false }
            else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") { quoted.toggle() }
            else if !quoted {
                if byte == UInt8(ascii: "{") { depth += 1 }
                else if byte == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 { return start..<(i + 1) }
                }
            }
            i += 1
        }
        return nil
    }

    // Every occurrence — one cache file can hold several entries of a kind.
    private static func spans(of marker: Data, in data: Data) -> [Range<Int>] {
        var out: [Range<Int>] = [], from = data.startIndex
        while let span = span(of: marker, in: data, from: from) {
            out.append(span)
            from = span.upperBound
        }
        return out
    }

    private static func dict(at span: Range<Int>, in data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data[span])) as? [String: Any]
    }

    // The tile every space's library page loads: the CDN path names the space id
    // itself — the deterministic cover for a space no games/api body was cached for.
    static func tile(_ spaceID: String) -> URL? {
        URL(string: "https://ubiservices.cdn.ubi.com/\(spaceID)/ConnectPC/backgroundTileImageId.jpg")
    }

    private static func readCapped(_ url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? Int,
              size <= fileLimit else { return nil }
        return try? Data(contentsOf: url)
    }

    // The launcher's own install dir first (where the cache sits), then the user-level
    // copy older builds keep under LocalAppData.
    static func roots(prefix: URL) -> [URL] {
        var roots: [URL] = []
        if let dir = launcherDirectory(prefix: prefix) { roots.append(dir.appending(path: "cache")) }
        roots.append(PrefixPaths.localAppData(prefix).appending(path: "Ubisoft Game Launcher/cache"))
        return roots
    }

    // HKLM\SOFTWARE\WOW6432Node\Ubisoft\Launcher -> InstallDir, else the standard spot.
    static func launcherDirectory(prefix: URL) -> URL? {
        if let text = WineRegistry.read(prefix: prefix),
           let dir = WineRegistry.values(text, in: #"Software\Wow6432Node\Ubisoft\Launcher"#)?["installdir"],
           let url = WinePath.unix(dir, prefix: prefix) { return url }
        let standard = prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher")
        return FileManager.default.fileExists(atPath: standard.path(percentEncoded: false)) ? standard : nil
    }

    static func owned(_ message: ProtobufMessage) -> [UbisoftOwned] {
        message.messages(1).compactMap(UbisoftOwned.init)
    }

    static func configurations(_ message: ProtobufMessage) -> [Int: UbisoftConfig] {
        var out: [Int: UbisoftConfig] = [:]
        for record in message.messages(1) {
            guard let productID = record.int(1).flatMap(Int.init(exactly:)),
                  let uplayID = record.int(2).flatMap(Int.init(exactly:)),
                  let yaml = record.string(3) else { continue }
            let card = UbisoftYAML.map(yaml)
            let name = UbisoftYAML.string(card, "root", "name")
            let localized = name.flatMap { UbisoftYAML.strings(card, "localizations", "default")?[$0] }
            out[productID] = UbisoftConfig(
                productID: productID, uplayID: uplayID, name: name ?? "", localizedName: localized,
                artName: UbisoftYAML.string(card, "root", "thumb_image"),
                headerName: UbisoftYAML.string(card, "root", "background_image"))
        }
        return out
    }
}
