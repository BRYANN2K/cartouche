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

    // Elden Ring is Windows only, Baldur's Gate 3 and Cyberpunk 2077 have a Mac build,
    // Hollow Knight lists both with a number and a nested section around its oslist,
    // an app with no oslist is Windows, a Mac-only app has no Windows version to pick
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

    @Test("A cache cut short or of an unknown format is refused rather than read in part")
    func refusals() throws {
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(Self.cache(.v28, ended: false)) }
        var unknown = Self.cache(.v28)
        unknown[0] = 0x26
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(unknown) }
        let cut = Array(Self.cache(.v29).prefix(40))
        #expect(throws: SteamAppInfo.Failure.self) { try SteamAppInfo.platforms(cut) }
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
