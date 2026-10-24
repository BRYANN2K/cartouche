import Foundation
import Testing

@testable import NotProtonApp

// Synthetic appinfo.vdf caches in the three formats Steam has written (v27, v28 and the
// v29 string table), built here. Steam's own cache is never read.
@Suite("Mac builds from appinfo")
struct SteamAppInfoTests {

    private struct Bytes {
        var bytes: [UInt8] = []
        mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) } }
        mutating func cstring(_ s: String) { bytes.append(contentsOf: Array(s.utf8)); bytes.append(0) }
    }

    enum Format { case v27, v28, v29 }

    static let table = ["appinfo", "common", "name", "oslist", "steam_release_date", "depots", "config"]

    static let apps: [(UInt32, String?)] = [
        (1_245_620, "windows"), (1_086_940, "windows,macos"), (1_091_500, "macos,windows"),
        (367_520, "windows,macos,linux"), (440, nil), (12_345, "macos"),
    ]

    private static func entry(_ appID: UInt32, _ oslist: String?, format: Format, common: Bool = true) -> [UInt8] {
        var kv = Bytes()
        func key(_ name: String) {
            if format == .v29 { kv.u32(UInt32(table.firstIndex(of: name)!)) } else { kv.cstring(name) }
        }
        kv.bytes.append(0x00); key("appinfo")
        if common {
            kv.bytes.append(0x00); key("common")
            kv.bytes.append(0x01); key("name"); kv.cstring("App \(appID)")
            kv.bytes.append(0x02); key("steam_release_date"); kv.u32(1_600_000_000)
            if let oslist { kv.bytes.append(0x01); key("oslist"); kv.cstring(oslist) }
            kv.bytes.append(0x08)
        }
        // A depots section with its own oslist, which is not the game's
        kv.bytes.append(0x00); key("depots")
        kv.bytes.append(0x00); key("config")
        kv.bytes.append(0x01); key("oslist"); kv.cstring("linux")
        kv.bytes.append(contentsOf: [0x08, 0x08])
        kv.bytes.append(contentsOf: [0x08, 0x08])
        let header = format == .v27 ? 40 : 60
        var e = Bytes()
        e.u32(appID)
        e.u32(UInt32(header + kv.bytes.count))
        e.bytes.append(contentsOf: [UInt8](repeating: 0, count: header))
        e.bytes.append(contentsOf: kv.bytes)
        return e.bytes
    }

    static func cache(_ format: Format, ended: Bool = true) -> [UInt8] {
        var entries = Bytes()
        for (id, oslist) in apps { entries.bytes.append(contentsOf: entry(id, oslist, format: format)) }
        entries.bytes.append(contentsOf: entry(99, nil, format: format, common: false))
        if ended { entries.u32(0) }
        var file = Bytes()
        switch format {
        case .v27: file.u32(0x0756_4427)
        case .v28: file.u32(0x0756_4428)
        case .v29: file.u32(0x0756_4429)
        }
        file.u32(1)
        if format == .v29 {
            file.u64(UInt64(16 + entries.bytes.count))
            file.bytes.append(contentsOf: entries.bytes)
            file.u32(UInt32(table.count))
            for key in table { file.cstring(key) }
        } else {
            file.bytes.append(contentsOf: entries.bytes)
        }
        return file.bytes
    }

    @Test("Games with a macOS build next to the Windows one are found in every cache format",
          arguments: [Format.v27, .v28, .v29])
    func macBuilds(_ format: Format) throws {
        let found = try SteamAppInfo.platforms(Self.cache(format))
        #expect(found.both == [1_086_940, 1_091_500, 367_520])
        #expect(found.mac == [1_086_940, 1_091_500, 367_520, 12_345])
        #expect(found.windows == [1_245_620, 1_086_940, 1_091_500, 367_520, 440], "no oslist means Windows")
        #expect(!found.windows.contains(99) && !found.mac.contains(99), "an app with no common section is neither")
    }

    @Test("Storage estimates use public depots for the selected OS, excluding optional DLC and other languages")
    func storageSizes() {
        typealias V = AppInfoVDF.Value
        func depot(_ bytes: V, os: String? = nil, language: String? = nil, dlc: Bool = false) -> V {
            var config: [String: V] = [:]
            if let os { config["oslist"] = .string(os) }
            if let language { config["language"] = .string(language) }
            var depot: [String: V] = ["config": .section(config), "manifests": .section(["public": .section(["size": bytes])])]
            if dlc { depot["dlcappid"] = .number(99) }
            return .section(depot)
        }
        let app: [String: V] = ["depots": .section([
            "1": depot(.string("10000000000")),
            "2": depot(.number(2_000_000_000), os: "macos"),
            "3": depot(.number(4_000_000_000), os: "windows"),
            "4": depot(.number(20_000_000_000), dlc: true),
            "5": depot(.number(1_000_000_000), language: "german"),
            "6": depot(.string("invalid")), "7": depot(.number(-1))
        ])]
        #expect(SteamAppInfo.storage(app) == .init(windows: 14_000_000_000, mac: 12_000_000_000))
    }

    @Test("A cache cut short or of an unknown format is refused rather than read in part")
    func refusals() throws {
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(Self.cache(.v28, ended: false)) }
        var unknown = Self.cache(.v28)
        unknown[0] = 0x26
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(unknown) }
        let cut = Array(Self.cache(.v29).prefix(40))
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(cut) }
    }

    @Test("A string table claiming more strings than bytes left is refused before anything is reserved")
    func hugeStringTableCount() throws {
        var bytes = Bytes()
        bytes.u32(0xffff_ffff)
        bytes.cstring("appinfo")
        #expect(throws: AppInfoVDF.ParseError.truncated) { try AppInfoVDF.readStringTable(bytes.bytes, at: 0) }
        var table = Self.cache(.v29)
        let start = table.count - Self.table.reduce(4) { $0 + $1.utf8.count + 1 }
        table.replaceSubrange(start..<start + 4, with: [0xff, 0xff, 0xff, 0x7f])
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(table) }
        var exact = Bytes()
        exact.u32(2)
        exact.cstring("a")
        exact.cstring("b")
        #expect(try AppInfoVDF.readStringTable(exact.bytes, at: 0) == ["a", "b"])
    }

    @Test("The file is read from a path, and a missing one gives nothing")
    func fromFile() throws {
        let work = try scratchDirectory("appinfo")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "appinfo.vdf")
        try Data(Self.cache(.v29)).write(to: file)
        #expect(SteamAppInfo.platforms(at: file)?.both == [1_086_940, 1_091_500, 367_520])
        #expect(SteamAppInfo.platforms(at: work.appending(path: "none.vdf")) == nil)
        #expect(SteamAppInfo.cache.path(percentEncoded: false).hasSuffix("/Steam/appcache/appinfo.vdf"))
    }

    @Test("File results are reused until the URL, modification time, or size changes")
    func fileCacheInvalidation() throws {
        let work = try scratchDirectory("appinfo-cache")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "appinfo.vdf")
        let other = work.appending(path: "other.vdf")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        var bytes = Self.cache(.v28)
        try Data(bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        var reads = 0
        let cache = SteamAppInfo.FileCache { url in
            reads += 1
            return try Data(contentsOf: url)
        }
        let first = cache.platforms(at: file)
        #expect(first?.windows.contains(1_245_620) == true)
        #expect(cache.platforms(at: file) == first)
        #expect(reads == 1)

        // Same size, newer modification time, different first app ID.
        bytes[8] += 1
        try Data(bytes).write(to: file)
        let newer = modified.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: file.path)
        #expect(cache.platforms(at: file)?.windows.contains(1_245_621) == true)
        #expect(reads == 2)

        // A changed size invalidates even when the modification time stays fixed.
        bytes.append(0)
        try Data(bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: file.path)
        #expect(cache.platforms(at: file)?.windows.contains(1_245_621) == true)
        #expect(reads == 3)
        #expect(cache.platforms(at: file) != nil)
        #expect(reads == 3)

        // A different URL must not borrow the first file's matching stamp.
        bytes[8] -= 1
        try Data(bytes).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: other.path)
        #expect(cache.platforms(at: other)?.windows.contains(1_245_620) == true)
        #expect(reads == 4)
    }

    @Test("In the library a game with a Mac build reads Mac version until the Windows version is picked")
    @MainActor
    func libraryShowsVersion() async throws {
        let fixture = try SteamFixture("appinfo-library")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = ScratchDefaults()
        let model = libraryModel(fixture, defaults: defaults)
        await model.load()
        model.macBuilds = try SteamAppInfo.platforms(Self.cache(.v29)).both
        let cyberpunk = try #require(model.game("steam:1091500"))
        #expect(cyberpunk.version == .mac && cyberpunk.status() == "Mac version")
        #expect(model.game("steam:1245620")?.version == nil, "Elden Ring has no Mac build")
        var choice = model.setup(for: cyberpunk.id)
        choice.version = .windows
        model.setSetup(choice, for: cyberpunk.id)
        #expect(model.game("steam:1091500")?.status() == "Windows version")
    }
}
