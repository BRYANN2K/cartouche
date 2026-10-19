import Foundation
import Testing

@testable import RetroArchKit

// The user's retroarch.cfg, where RetroArch itself would look for it, keeps
// its bytes however often Cartouche runs RetroArch
extension IntegrationTests {

    @Test func userConfigUntouchedAfterTenRuns() async throws {
        let game = try Game("tenruns")
        let before = try Self.sha256(game.userConfig)
        for _ in 1...10 {
            let session = game.session()
            try await session.start()
            try await session.load(core: Rig.testCore!, content: game.rom)
            try await session.saveState(slot: 1)
            #expect(await session.stop().way == .quit)
        }
        #expect(try Self.sha256(game.userConfig) == before)
        print("evidence: user retroarch.cfg sha256 before \(before), after ten runs \(try Self.sha256(game.userConfig))")
        // RetroArch ran on Cartouche's own retroarch.cfg instead
        #expect(FileManager.default.fileExists(atPath: game.paths.baseConfig.path))
    }

    // The check above can see a rewrite: run on the user's file, with
    // cartouche.cfg's guard lifted, RetroArch saves over it on its first exit
    @Test func aRewriteWouldBeSeen() async throws {
        let game = try Game("rewrite")
        let before = try Self.sha256(game.userConfig)
        let session = game.session(["config_save_on_exit": "true"], baseConfig: .retroarchDefault)
        try await session.start()
        _ = await session.stop()
        #expect(try Self.sha256(game.userConfig) != before)
    }
}
