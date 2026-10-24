import Foundation
import Testing

@testable import NotProtonApp

@Suite("GOG panel details", .serialized)
@MainActor
struct GOGDetailsTests {
    @Test("GOG details reach the panel and survive restart without fetching again")
    func cachedDetails() async throws {
        let scene = try await StoreScene("gog-details", gogServer: true)
        defer { scene.remove() }
        await scene.center.finishSignIn(.gog, code: "gog-good-code")
        let game = try #require(scene.model.game("gog:1207658924"))
        await scene.center.loadDetails(game)
        let updated = try #require(scene.model.game(game.id))
        #expect(updated.mediaHeader == URL(string: "https://images.gog.com/header.jpg"))
        #expect(updated.mediaScreenshots == [URL(string: "https://images.gog.com/shot.jpg")!])
        #expect(updated.storageBytes == 92_000_000_000)
        #expect(updated.storageEstimated)
        let infoCalls = scene.calls("gogdl").filter { $0.contains("info 1207658924 --platform windows --skip-dlcs") }
        #expect(infoCalls.count == 1)
        await scene.center.loadDetails(updated)
        #expect(scene.calls("gogdl").filter { $0.contains("info ") }.count == 1)
        let reloaded = scene.makeCenter(folders: scene.folders, vault: scene.vault, library: nil)
        await reloaded.start(refresh: false)
        let saved = try #require(reloaded.libraryGames().first { $0.id == game.id })
        #expect(saved.mediaHeader == updated.mediaHeader)
        #expect(saved.storageBytes == updated.storageBytes)
    }

    @Test("Old cached library records still decode, and missing sizes stay unknown")
    func legacyAndMissing() throws {
        let game = try JSONDecoder().decode(StoreGame.self, from: Data(#"{"id":"1","title":"Game","cloudSaves":false}"#.utf8))
        #expect(game.screenshots == nil && game.diskBytes == nil)
        #expect(GOGAdapter.sizes([:]) == nil)
        #expect(GOGAdapter.sizes(["size": ["*": ["download_size": -1, "disk_size": 10]]]) == nil)
    }
}
