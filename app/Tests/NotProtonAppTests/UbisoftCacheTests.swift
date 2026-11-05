import Foundation
import Testing

@testable import NotProtonApp

// The launcher-local caches Cartouche reads after a Ubisoft Connect sign-in. The bytes
// below are fixtures built field-by-field from UplayDB's dumped proto2 schemas
// (ownership_cache.proto, configuration.proto — MIT, reference only); no account data.
@Suite("Ubisoft local cache", .serialized)
struct UbisoftCacheTests {

    // A proto2 writer for fixtures: tag, varint and length-delimited fields only.
    enum Protobuf {
        static func varint(_ value: UInt64) -> Data {
            var v = value, out = Data()
            while v >= 0x80 { out.append(UInt8(v & 0x7f | 0x80)); v >>= 7 }
            out.append(UInt8(v))
            return out
        }
        static func tag(_ field: Int, _ wire: Int) -> Data { varint(UInt64(field << 3 | wire)) }
        static func int(_ field: Int, _ value: UInt64) -> Data { tag(field, 0) + varint(value) }
        static func bytes(_ field: Int, _ data: Data) -> Data { tag(field, 2) + varint(UInt64(data.count)) + data }
        static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
    }

    // product_id 720 / uplay_id 540 (Harbor Lords's real ids), one second game, one DLC
    static let game = Protobuf.int(1, 720) + Protobuf.int(2, 540) + Protobuf.int(5, 1) + Protobuf.int(6, 0)
        + Protobuf.int(7, 3) + Protobuf.int(8, 721) + Protobuf.int(8, 722) + Protobuf.string(10, "ANNO1800")
    static let second = Protobuf.int(1, 13504) + Protobuf.int(2, 13504) + Protobuf.int(5, 1) + Protobuf.int(6, 0)
        + Protobuf.int(7, 3) + Protobuf.string(10, "TRACKMANIA")
    static let dlc = Protobuf.int(1, 9999) + Protobuf.int(5, 1) + Protobuf.int(6, 3) + Protobuf.int(7, 3)
    static let ownership = Protobuf.bytes(1, game) + Protobuf.bytes(1, second) + Protobuf.bytes(1, dlc)
        + Protobuf.int(2, 720) + Protobuf.int(2, 13504) + Protobuf.int(3, 720) + Protobuf.int(3, 13504)

    static let configYAML = """
    version: 2
    root:
      name: Harbor Lords
      thumb_image: anno1800_thumb.png
      icon_image: anno1800_icon.png
      background_image: anno1800_background.jpg
      logo_image: anno1800_logo.png
    localizations:
      default:
        Harbor Lords: Anno mille huit cent
    thirdparty:
      steam:
        app_id: 0
    """

    static let configuration = Protobuf.int(1, 720) + Protobuf.int(2, 540) + Protobuf.string(3, configYAML)
    static let configurations = Protobuf.bytes(1, configuration)

    // The sealed .vdat container the current launcher writes: a protobuf envelope whose
    // versioned header (key id, 12-byte nonce, 16-byte tag) precedes the sealed body.
    // Synthetic bytes — the real body is encrypted and nothing here tries to read it.
    static let vdat = Protobuf.bytes(1,
        Protobuf.int(1, 1)
            + Protobuf.bytes(2, Protobuf.int(1, 1)
                               + Protobuf.bytes(2, Data("0123456789abcdef0123456789abcdef".utf8))
                               + Protobuf.bytes(3, Data(repeating: 0xab, count: 12))
                               + Protobuf.bytes(4, Data(repeating: 0xcd, count: 16)))
            + Protobuf.bytes(3, Data())
            + Protobuf.bytes(2, Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 * 31 &+ 7) })))

    @Test("protobuf wire: varints, packed lists, nested messages, and truncated data fails")
    func wire() throws {
        let message = try ProtobufMessage(Self.ownership)
        #expect(message.ints(2) == [720, 13504])
        let owned = message.messages(1)
        #expect(owned.count == 3)
        #expect(owned[0].int(1) == 720 && owned[0].int(2) == 540)
        #expect(owned[0].ints(8) == [721, 722])
        #expect(owned[0].string(10) == "ANNO1800")
        #expect(owned[0].int(99) == nil && owned[0].string(4) == nil)
        // A packed list reads the same as repeated varints
        let packed = Protobuf.bytes(8, Protobuf.varint(9) + Protobuf.varint(10))
        #expect(try ProtobufMessage(packed).ints(8) == [9, 10])
        #expect(throws: Error.self) { try ProtobufMessage(Data([0x0a, 0xff, 0x01])) }
        #expect(throws: Error.self) { try ProtobufMessage(Data([0x0b])) } // groups: not in the caches
    }

    @Test("the YAML product card: nested maps, quoted scalars, localized names")
    func yaml() throws {
        let map = UbisoftYAML.map(Self.configYAML)
        #expect(UbisoftYAML.string(map, "root", "name") == "Harbor Lords")
        #expect(UbisoftYAML.string(map, "root", "thumb_image") == "anno1800_thumb.png")
        #expect(UbisoftYAML.string(map, "root", "background_image") == "anno1800_background.jpg")
        #expect(UbisoftYAML.strings(map, "localizations", "default")?["Harbor Lords"] == "Anno mille huit cent")
        #expect(UbisoftYAML.string(map, "missing", "key") == nil)
        let quoted = UbisoftYAML.map("root:\n  name: \"Quoted: Game\" # remark\n  empty:\n")
        #expect(UbisoftYAML.string(quoted, "root", "name") == "Quoted: Game")
        #expect(UbisoftYAML.string(quoted, "root", "empty") == nil)
    }

    @Test("ownership and configurations decode to the cache model")
    func decode() throws {
        var cache = UbisoftCache()
        let owned = try UbisoftLocalCache.owned(ProtobufMessage(Self.ownership))
        #expect(owned.map(\.productID) == [720, 13504, 9999])
        #expect(owned[0].uplayID == 540 && owned[0].gameCode == "ANNO1800")
        #expect(owned[0].platform == 1 && owned[0].productType == 0 && owned[0].state == 3)
        let visible = try ProtobufMessage(Self.ownership).ints(3).map { Int($0) }
        #expect(visible == [720, 13504])
        let configs = try UbisoftLocalCache.configurations(ProtobufMessage(Self.configurations))
        let config = try #require(configs[720])
        #expect(config.uplayID == 540)
        #expect(config.title == "Anno mille huit cent")
        #expect(config.name == "Harbor Lords")
        #expect(config.art == URL(string: "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/anno1800_thumb.png"))
        #expect(config.header == URL(string: "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/anno1800_background.jpg"))
    }

    // A fixture prefix as a signed-in Ubisoft Connect leaves it: the launcher's install
    // dir holds cache/ownership/<user_id> and cache/configuration/configurations — or,
    // sealed, the <user_id>.vdat and configurations.vdat the current launcher writes.
    static func writeCache(into prefix: URL, installDir: Bool = true, sealed: Bool = false) throws {
        let base = installDir
            ? prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/cache")
            : prefix.appending(path: "drive_c/users/crossover/AppData/Local/Ubisoft Game Launcher/cache")
        try FileManager.default.createDirectory(at: base.appending(path: "ownership"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appending(path: "configuration"), withIntermediateDirectories: true)
        try (sealed ? Self.vdat : Self.ownership).write(to: base.appending(
            path: "ownership/00000000-dead-beef-0000-000000000042" + (sealed ? ".vdat" : "")))
        try (sealed ? Self.vdat : Self.configurations).write(to: base.appending(
            path: "configuration/configurations" + (sealed ? ".vdat" : "")))
    }

    // The bodies the launcher's own HTTP cache keeps: the fetched entitlements list,
    // the store index (spaceId -> title) and the games/api cards a space's page leaves
    // (displayName + imageUrls) — each padded with entry metadata as a real cache entry is.
    // 720 and 721 are two editions of one space; space-three has a card but no index hit;
    // the locked and non-game items are not games.
    static func writeHTTPBodies(into prefix: URL) throws {
        let dir = prefix.appending(path: "drive_c/users/crossover/AppData/Local/Ubisoft Game Launcher/cache"
            + "/http2/Default/Service Worker/CacheStorage/test-cache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entitlements = #"""
        {"entitlements":[
          {"productId":720,"spaceId":"space-one","type":"game","accessLevel":"owned"},
          {"productId":721,"spaceId":"space-one","type":"game","accessLevel":"owned"},
          {"productId":13504,"spaceId":"space-two","type":"game","accessLevel":"owned"},
          {"productId":730,"spaceId":"space-three","type":"game","accessLevel":"owned"},
          {"productId":8,"spaceId":"space-sub","type":"game","accessLevel":"locked"},
          {"productId":9,"spaceId":"space-one","type":"addon","accessLevel":"owned"}]}
        """#
        let index = #"""
        {"hits":[{"title":"Fixture Game One","availabilities":[{"spaceId":"space-one"}]},
                 {"title":"Fixture Game Two","availabilities":[{"spaceId":"space-two"}]}],"nbHits":2}
        """#
        let spaceThree = #"""
        {"spaceId":"space-three","installmentSpaceId":"inst-three","displayName":"Fixture Game Three",
         "siblingGames":[],"imageUrls":{"lowThumbnail":"https://cdn.ubi.test/low.jpg",
         "highThumbnail":"https://cdn.ubi.test/high.jpg","background":"https://cdn.ubi.test/bg.jpg",
         "lowBoxArt":"https://cdn.ubi.test/box.jpg"},"linkUrls":{}}
        """#
        let batch = #"""
        {"games":[{"spaceId":"space-batch","installmentSpaceId":"inst-batch",
         "displayName":"Fixture Batch","imageUrls":{"highBoxArt":"https://cdn.ubi.test/batch-box.jpg"}}]}
        """#
        // The GraphQL/products answer the launcher's library pages cache: the game's
        // own name, its portrait `image`, and the wide `coverImage` for the panel.
        let product = #"""
        {"productId":"prod-uuid-one","spaceId":"space-one","name":"Fixture Product One",
         "image":"https://cdn.ubi.test/one-box.jpg","coverImage":"https://cdn.ubi.test/one-bg.jpg"}
        """#
        try (Data([0xde, 0xad]) + Data(entitlements.utf8) + Data([0xbe, 0xef])).write(to: dir.appending(path: "aaaa_0"))
        try (Data("entry headers".utf8) + Data(index.utf8)).write(to: dir.appending(path: "bbbb_0"))
        try (Data("entry headers".utf8) + Data(spaceThree.utf8)).write(to: dir.appending(path: "cccc_0"))
        try (Data("entry headers".utf8) + Data(batch.utf8)).write(to: dir.appending(path: "dddd_0"))
        try (Data("entry headers".utf8) + Data(product.utf8)).write(to: dir.appending(path: "eeee_0"))
    }

    @Test("read() joins both caches and names the signed-in account")
    func read() throws {
        let root = try scratchDirectory("ubisoft-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        try Self.writeCache(into: prefix)
        let cache = try UbisoftLocalCache.read(prefix: prefix)
        #expect(cache.userID == "00000000-dead-beef-0000-000000000042")
        #expect(cache.owned.count == 3 && cache.visibleIDs == [720, 13504])
        #expect(cache.configs[720]?.title == "Anno mille huit cent")
        // The LocalAppData copy works the same way
        let other = root.appending(path: "pfx2")
        try Self.writeCache(into: other, installDir: false)
        #expect(try UbisoftLocalCache.read(prefix: other).userID == "00000000-dead-beef-0000-000000000042")
        // The registry InstallDir wins when it points somewhere else
        let reg = root.appending(path: "pfx3")
        try FileManager.default.createDirectory(at: reg, withIntermediateDirectories: true)
        let install = reg.appending(path: "drive_c/Games/Ubisoft Connect/cache")
        try FileManager.default.createDirectory(at: install.appending(path: "ownership"), withIntermediateDirectories: true)
        try Self.ownership.write(to: install.appending(path: "ownership/user-7"))
        try LauncherStoreTests.systemReg
            .replacingOccurrences(of: "C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher", with: "C:\\\\Games\\\\Ubisoft Connect")
            .write(to: reg.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        #expect(try UbisoftLocalCache.read(prefix: reg).userID == "user-7")
        // No cache anywhere: the launcher never signed in
        #expect(throws: StoreError.self) { try UbisoftLocalCache.read(prefix: root.appending(path: "empty-pfx")) }
    }

    @Test("The sealed .vdat caches: the session still counts, the unreadable list stays empty")
    func sealed() throws {
        let root = try scratchDirectory("ubisoft-sealed")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        try Self.writeCache(into: prefix, installDir: false, sealed: true)
        let cache = try UbisoftLocalCache.read(prefix: prefix)
        #expect(cache.userID == "00000000-dead-beef-0000-000000000042")
        #expect(cache.owned.isEmpty && cache.visibleIDs.isEmpty && cache.configs.isEmpty)
        #expect(cache.ownershipModified != nil)
        // The watcher and sign-out use the account id, never the file name
        #expect(UbisoftLocalCache.userID(prefix: prefix) == "00000000-dead-beef-0000-000000000042")
        UbisoftLocalCache.forget(prefix: prefix, account: "00000000-dead-beef-0000-000000000042")
        #expect(UbisoftLocalCache.userID(prefix: prefix) == nil)
        #expect(throws: StoreError.self) { try UbisoftLocalCache.read(prefix: prefix) }
    }

    @Test("The sealed .vdat plus the launcher's HTTP cache: the fetched list still names owned games")
    func httpBodies() throws {
        let root = try scratchDirectory("ubisoft-http")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        try Self.writeCache(into: prefix, installDir: false, sealed: true)
        try Self.writeHTTPBodies(into: prefix)
        let cache = try UbisoftLocalCache.read(prefix: prefix)
        // Owned games only — editions stay separate products, locked and non-game items are out
        #expect(cache.owned.map(\.productID) == [720, 721, 13504, 730])
        #expect(cache.visibleIDs == [720, 721, 13504, 730])
        #expect(cache.titles == ["space-one": "Fixture Game One", "space-two": "Fixture Game Two"])
        // The games/api cards name the space the index does not and carry the image URLs
        let three = try #require(cache.spaces["space-three"])
        #expect(three.name == "Fixture Game Three")
        #expect(three.art == URL(string: "https://cdn.ubi.test/box.jpg"))
        #expect(three.header == URL(string: "https://cdn.ubi.test/bg.jpg"))
        #expect(cache.spaces["space-batch"]?.art == URL(string: "https://cdn.ubi.test/batch-box.jpg"))
        // The products body names the space too and splits portrait art from panel art
        let one = try #require(cache.spaces["space-one"])
        #expect(one.name == "Fixture Product One")
        #expect(one.art == URL(string: "https://cdn.ubi.test/one-box.jpg"))
        #expect(one.header == URL(string: "https://cdn.ubi.test/one-bg.jpg"))
        // A space no card was cached for still has a cover: the launcher's own tile name
        #expect(UbisoftLocalCache.tile("space-nine")
            == URL(string: "https://ubiservices.cdn.ubi.com/space-nine/ConnectPC/backgroundTileImageId.jpg"))
        // Without the HTTP copy the sealed cache alone still yields the valid empty list
        try? FileManager.default.removeItem(at: prefix.appending(
            path: "drive_c/users/crossover/AppData/Local/Ubisoft Game Launcher/cache/http2"))
        #expect(try UbisoftLocalCache.read(prefix: prefix).owned.isEmpty)
    }

    @Test("The account id never reaches the screen: the uuid and its .vdat name are hidden")
    func hiddenAccount() throws {
        #expect(StoreConnection.shownAccount("00000000-dead-beef-0000-000000000042").isEmpty)
        #expect(StoreConnection.shownAccount("00000000-dead-beef-0000-000000000042.vdat").isEmpty)
        #expect(StoreConnection.shownAccount("player42") == "player42")
        #expect(StoreConnection.shownAccount("player42.vdat") == "player42")
    }

    @Test("A hostile cache degrades instead of crashing: huge lengths, ids and files are skipped")
    func hostile() throws {
        // A length-delimited field claiming UInt64.max bytes must fail, not trap
        #expect(throws: Error.self) {
            try ProtobufMessage(Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]))
        }
        // A length of Int.max must not overflow i + count either
        #expect(throws: Error.self) {
            try ProtobufMessage(Data([0x0a]) + Protobuf.varint(UInt64(Int.max)))
        }
        // An owned record whose ids do not fit an Int is skipped, not fatal
        let hostileOwned = try ProtobufMessage(
            Protobuf.bytes(1, Protobuf.int(1, UInt64.max) + Protobuf.string(10, "BAD"))
                + Protobuf.bytes(1, Self.game))
        #expect(UbisoftLocalCache.owned(hostileOwned).map(\.productID) == [720])
        // The same for the visible-id list and the configuration cards
        let visible = try ProtobufMessage(Protobuf.int(3, UInt64.max) + Protobuf.int(3, 720))
        #expect(visible.ints(3).compactMap(Int.init(exactly:)) == [720])
        let hostileConfig = try ProtobufMessage(
            Protobuf.bytes(1, Protobuf.int(1, UInt64.max) + Protobuf.int(2, 540) + Protobuf.string(3, Self.configYAML))
                + Protobuf.bytes(1, Self.configuration))
        #expect(UbisoftLocalCache.configurations(hostileConfig).keys.sorted() == [720])
        // YAML nested past any real card returns instead of exhausting the stack
        var deep = "k:"
        for level in 1...4000 { deep += "\n" + String(repeating: " ", count: level) + "k:" }
        _ = UbisoftYAML.map(deep)
        // A cache file past the read bound is skipped like a missing one
        let root = try scratchDirectory("ubisoft-hostile")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        try Self.writeCache(into: prefix)
        let ownershipDir = prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/cache/ownership")
        try Data(repeating: 0xff, count: 70 * 1024 * 1024)
            .write(to: ownershipDir.appending(path: "zzz-huge-account"))
        let cache = try UbisoftLocalCache.read(prefix: prefix)
        #expect(cache.userID == "zzz-huge-account")
        #expect(cache.owned.isEmpty && cache.visibleIDs.isEmpty)
        #expect(cache.configs[720]?.title == "Anno mille huit cent")
    }

    @Test("With several cached accounts the active one is the latest written; forget() clears it")
    func activeAccount() throws {
        let root = try scratchDirectory("ubisoft-accounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "pfx")
        try Self.writeCache(into: prefix)
        let ownershipDir = prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/cache/ownership")
        // A second account whose name sorts BEFORE the session's: lexicographic would pick it,
        // but the launcher rewrote its own file last, so it is the active one.
        let older = ownershipDir.appending(path: "00000000-0000-0000-0000-000000000001")
        try Self.second.write(to: older)
        let active = ownershipDir.appending(path: "00000000-dead-beef-0000-000000000042")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: older.path(percentEncoded: false))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: active.path(percentEncoded: false))
        #expect(try UbisoftLocalCache.read(prefix: prefix).userID == "00000000-dead-beef-0000-000000000042")
        // The stale file alone is still a valid session for its own account
        try? FileManager.default.removeItem(at: active)
        #expect(try UbisoftLocalCache.read(prefix: prefix).userID == "00000000-0000-0000-0000-000000000001")
    }
}
