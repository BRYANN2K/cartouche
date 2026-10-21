import Foundation
import Testing

@testable import NotProtonApp

@Suite("Game panel store pictures")
struct GameMediaTests {
    @Test("Header and screenshots are cached for offline browsing")
    func offlinePictures() async throws {
        let fixture = try SteamFixture("panel-media")
        defer { fixture.remove() }
        let image = try SteamFixture.png("Header", size: CGSize(width: 460, height: 215), hue: 0.2)
        let shot = URL(string: "https://example.com/screenshot.jpg")!
        let data = try JSONSerialization.data(withJSONObject: ["42": ["success": true, "data": [
            "header_image": "https://example.com/header.jpg",
            "screenshots": [["path_full": shot.absoluteString]]
        ]]])
        let store = GameMediaStore(covers: fixture.covers { url in
            url.path == "/api/appdetails" ? (data, 200) : (image, 200)
        })
        let shots = await store.screenshots(42, online: true)
        #expect(shots == [shot])
        let header = try #require(await store.header(42, online: true))
        let screenshot = try #require(await store.local(shot, appID: 42, online: true))
        let offline = GameMediaStore(covers: fixture.covers())
        #expect(await offline.screenshots(42, online: false) == shots)
        #expect(await offline.header(42, online: false) == header)
        #expect(await offline.local(shot, appID: 42, online: false) == screenshot)
    }

    @Test("Missing media and failed store responses do not create picture files")
    func missingPictures() async throws {
        let fixture = try SteamFixture("panel-media-missing")
        defer { fixture.remove() }
        let store = GameMediaStore(covers: fixture.covers { _ in (Data("not an image".utf8), 404) })
        #expect(await store.screenshots(42, online: true).isEmpty)
        #expect(await store.header(42, online: true) == nil)
        #expect(await store.local(URL(string: "https://example.com/missing.jpg")!, appID: 42, online: true) == nil)
        #expect(GameMediaStore.parse(Data("{}".utf8), appID: 42).isEmpty)
    }
}
