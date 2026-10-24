import Foundation
import Testing

@testable import NotProtonApp

// Two Macs on one GOG account, each with its own Cartouche folder, prefix and
// vault. gogdl's stand-in keeps the account's cloud in one folder both reach, as
// GOG's servers would. The real two-Mac check is the maintainer's (evidence.md).
@Suite("Store cloud saves", .serialized)
@MainActor
struct StoreSavesTests {

    private func mac(_ scene: StoreScene, _ name: String) async throws -> (StoreCenter, LibraryModel) {
        let model = libraryModel(scene.steam, defaults: scene.defaults)
        model.runners = [scene.runner]
        let center = scene.makeCenter(folders: StoreFolders(root: scene.work.appending(path: "\(name)/stores")), vault: MemoryVault(),
                                      library: model)
        await model.load()
        await center.beginSignIn(.gog)
        await center.finishSignIn(.gog, code: "gog-good-code")
        let game = try #require(model.game("gog:1207658924"))
        center.install(game)
        #expect(await scene.waitUntil { center.record(game.id) != nil })
        return (center, model)
    }

    private func play(_ center: StoreCenter, _ model: LibraryModel, _ scene: StoreScene) async throws {
        let game = try #require(model.game("gog:1207658924"))
        center.play(game)
        #expect(await scene.waitUntil { !center.playing.contains(game.id) })
        #expect(center.problem == nil)
    }

    @Test("A GOG save made on the first Mac is in the second Mac's prefix when the game starts there")
    func twoMacs() async throws {
        let scene = try await StoreScene("saves-two-macs", gogServer: true)
        defer { scene.remove() }
        let (first, firstModel) = try await mac(scene, "mac-a")
        let (second, secondModel) = try await mac(scene, "mac-b")

        try "slot 1, chapter 3, made on Mac A".write(to: scene.state.appending(path: "write-save"), atomically: true, encoding: .utf8)
        try await play(first, firstModel, scene)
        scene.flag("write-save", false)
        let uploaded = scene.state.appending(path: "cloud/1207658924/saves/slot1.sav")
        #expect(try String(contentsOf: uploaded, encoding: .utf8) == "slot 1, chapter 3, made on Mac A")

        try await play(second, secondModel, scene)
        let record = try #require(second.record("gog:1207658924"))
        let local = record.prefix.appending(path: "drive_c/users/crossover/Documents/Sample GOG Game/Saves/slot1.sav")
        #expect(try String(contentsOf: local, encoding: .utf8) == "slot 1, chapter 3, made on Mac A")
        // The game on Mac B found it at its start, before it could write anything
        #expect(scene.text("wine.calls").contains("found save: slot 1, chapter 3, made on Mac A"))
        let syncs = scene.text("gogdl.saves").split(separator: "\n")
        #expect(syncs.filter { $0.hasSuffix("--skip-upload") }.count == 2)
        #expect(syncs.filter { $0.hasSuffix("--skip-download") }.count == 2)
        print("evidence: save written on mac-a, read by the game on mac-b at \(local.path)")
    }

    @Test("Offline or with an expired session, the game starts without syncing, and syncs again once online")
    func offline() async throws {
        let scene = try await StoreScene("saves-offline", gogServer: true)
        defer { scene.remove() }
        let (center, model) = try await mac(scene, "mac-a")
        model.isOffline = true
        try await play(center, model, scene)
        #expect(scene.text("gogdl.saves").isEmpty)
        #expect(scene.calls("comet").isEmpty)
        model.isOffline = false
        try await play(center, model, scene)
        #expect(!scene.text("gogdl.saves").isEmpty)
    }
}
