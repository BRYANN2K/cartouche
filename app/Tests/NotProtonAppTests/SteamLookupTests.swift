import Foundation
import Testing

@testable import NotProtonApp

// A /api/storesearch answer, in the shape Steam returns.
private func entry(_ id: Int, _ name: String, _ type: String = "app") -> [String: Any] {
    ["id": id, "type": type, "name": name,
     "tiny_image": "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/capsule_231x87.jpg"]
}

private func searchAnswer(_ items: [[String: Any]]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["total": items.count, "items": items])) ?? Data()
}

private func item(_ appID: Int, _ name: String, _ kind: String = "app") -> SteamLookup.Item {
    SteamLookup.Item(appID: appID, name: name, kind: kind, capsule: nil)
}

@Suite("Steam store search")
struct SteamLookupTests {

    @Test("The answer parses: app IDs, names, kinds and capsule images")
    func parse() {
        let items = SteamLookup.items(in: searchAnswer([
            entry(2_100_001, "Cobalt Street"), entry(2_300_000, "Cobalt Street - Sunset Track", "dlc"),
        ]))
        #expect(items.count == 2)
        #expect(items[0] == SteamLookup.Item(appID: 2_100_001, name: "Cobalt Street", kind: "app",
                                           capsule: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/2100001/capsule_231x87.jpg")))
        #expect(items[0].isApp)
        #expect(!items[1].isApp)
        #expect(SteamLookup.items(in: Data("not json".utf8)).isEmpty)
    }

    @Test("The same name normalization the title index uses")
    func normalize() {
        #expect(SteamLookup.core("Cobalt Street") == ["cobalt", "street"])
        #expect(SteamLookup.core("Cobalt Street: Deluxe Edition") == ["cobalt", "street"])
        #expect(SteamLookup.core("Baldur’s Gate III") == ["baldurs", "gate", "3"])
        #expect(SteamLookup.core("The Witcher 3: Wild Hunt") == ["witcher", "3", "wild", "hunt"])
        #expect(SteamLookup.core("  !!!  ") == [])
    }

    @Test("Cobalt Street: the exact name wins over its own DLC and soundtrack")
    func exact() {
        let items = [
            item(2_100_001, "Cobalt Street"),
            item(635_140, "Cobalt Drift Online"),
            item(2_300_000, "Cobalt Street - Sunset Track", "dlc"),
            item(1_500_000, "Cobalt Street Soundtrack", "music"),
        ]
        #expect(SteamLookup.pick("Cobalt Street", in: items)?.appID == 2_100_001)
    }

    @Test("Edition words on either side still find the same game")
    func editions() {
        #expect(SteamLookup.pick("Fabledom", in: [item(42, "Fabledom: Definitive Edition")])?.appID == 42)
        #expect(SteamLookup.pick("Fabledom: Definitive Edition", in: [item(42, "Fabledom")])?.appID == 42)
        #expect(SteamLookup.pick("Elden Ring", in: [item(1_245_620, "ELDEN RING")])?.appID == 1_245_620)
    }

    @Test("DLC and soundtracks are never picked, even when only they match")
    func nonApps() {
        let items = [
            item(9, "Cobalt Street", "dlc"),
            item(8, "Cobalt Street Soundtrack", "music"),
        ]
        #expect(SteamLookup.pick("Cobalt Street", in: items) == nil)
    }

    @Test("Ambiguous names pick nothing; a single clear extension is still taken")
    func ambiguous() {
        let items = [
            item(1, "Need for Speed Heat"),
            item(2, "Need for Speed Payback"),
        ]
        #expect(SteamLookup.pick("Need for Speed", in: items) == nil)
        #expect(SteamLookup.pick("Need for Speed", in: [items[0]])?.appID == 1)
        // An unrelated app that only shares a first word is not an extension
        #expect(SteamLookup.pick("Cobalt Street", in: [item(635_140, "Cobalt Drift Online")]) == nil)
    }

    @Test("The endpoint is Steam's public store search, URL-encoded")
    func endpoint() throws {
        let url = try #require(SteamLookup.searchURL(term: "Cobalt Street & More"))
        #expect(url.absoluteString.hasPrefix("https://store.steampowered.com/api/storesearch/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "term" }?.value == "Cobalt Street & More")
        #expect(query.first { $0.name == "l" }?.value == "english")
        #expect(query.first { $0.name == "cc" }?.value == "US")
    }

    @Test("A found answer is asked for once and kept for a month")
    func foundCache() async throws {
        let dir = try scratchDirectory("lookup-found")
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Box<[URL]>([])
        let clock = Box(Date())
        var lookup = SteamLookup(directory: dir)
        lookup.now = { clock.value }
        lookup.fetch = { url in
            asked.value.append(url)
            return (searchAnswer([entry(2_100_001, "Cobalt Street")]), 200)
        }

        #expect(await lookup.match(for: "Cobalt Street")?.appID == 2_100_001)
        #expect(asked.value.count == 1)
        // The name is asked once, however often covers need it
        #expect(await lookup.match(for: "Cobalt Street")?.appID == 2_100_001)
        #expect(asked.value.count == 1)
        // Past a miss's day but inside the month, the cached answer still serves
        clock.value = clock.value.addingTimeInterval(SteamLookup.missTTL + 3600)
        #expect(await lookup.match(for: "Cobalt Street")?.appID == 2_100_001)
        #expect(asked.value.count == 1)
        // Past the month, the name is asked again
        clock.value = clock.value.addingTimeInterval(SteamLookup.foundTTL)
        #expect(await lookup.match(for: "Cobalt Street")?.appID == 2_100_001)
        #expect(asked.value.count == 2)
    }

    @Test("A decided no-match is remembered for a day")
    func missCache() async throws {
        let dir = try scratchDirectory("lookup-miss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Box<[URL]>([])
        let clock = Box(Date())
        var lookup = SteamLookup(directory: dir)
        lookup.now = { clock.value }
        lookup.fetch = { url in
            asked.value.append(url)
            return (searchAnswer([entry(7, "Something Else")]), 200)
        }

        #expect(await lookup.match(for: "Totally Unknown Game") == nil)
        #expect(await lookup.match(for: "Totally Unknown Game") == nil)
        #expect(asked.value.count == 1)
        clock.value = clock.value.addingTimeInterval(SteamLookup.missTTL + 1)
        #expect(await lookup.match(for: "Totally Unknown Game") == nil)
        #expect(asked.value.count == 2)
    }

    @Test("An unreachable Steam is retried after an hour, and a stale answer still serves")
    func failedCache() async throws {
        let dir = try scratchDirectory("lookup-failed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Box<[URL]>([])
        let clock = Box(Date())
        var lookup = SteamLookup(directory: dir)
        lookup.now = { clock.value }
        lookup.fetch = { url in asked.value.append(url); throw URLError(.notConnectedToInternet) }

        #expect(await lookup.match(for: "Cobalt Street") == nil)
        #expect(await lookup.match(for: "Cobalt Street") == nil)
        #expect(asked.value.count == 1)
        clock.value = clock.value.addingTimeInterval(SteamLookup.failedTTL + 1)
        #expect(await lookup.match(for: "Cobalt Street") == nil)
        #expect(asked.value.count == 2)

        // A name that was found before stays found while Steam is down
        clock.value = clock.value.addingTimeInterval(SteamLookup.failedTTL + 1)
        var found = SteamLookup(directory: dir)
        found.now = { clock.value }
        found.fetch = { _ in (searchAnswer([entry(2_100_001, "Cobalt Street")]), 200) }
        #expect(await found.match(for: "Cobalt Street")?.appID == 2_100_001)
        clock.value = clock.value.addingTimeInterval(SteamLookup.foundTTL + 1)
        found.fetch = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await found.match(for: "Cobalt Street")?.appID == 2_100_001)
    }

    @Test("The raw search returns every kind for the picker to filter")
    func search() async throws {
        let dir = try scratchDirectory("lookup-search")
        defer { try? FileManager.default.removeItem(at: dir) }
        var lookup = SteamLookup(directory: dir)
        lookup.fetch = { _ in
            (searchAnswer([entry(2_100_001, "Cobalt Street"), entry(2_300_000, "Cobalt Street - Pack", "dlc")]), 200)
        }
        let items = await lookup.search("Cobalt Street")
        #expect(items.map(\.appID) == [2_100_001, 2_300_000])
        lookup.fetch = { _ in throw URLError(.cannotFindHost) }
        #expect(await lookup.search("anything").isEmpty)
    }
}
