import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Game file verification UI", .serialized)
@MainActor
struct GameVerificationTests {
    private let game = Game(id: "installer:test", source: .installer, name: "Example", installed: true)

    @Test("Evidence levels remain distinct and Stop never marks files verified")
    func levels() {
        let model = FixtureGameVerification()
        #expect(model.status(for: game.id) == .notVerified)
        model.statuses[game.id] = .sizes
        #expect(model.status(for: game.id).title == "Verified (sizes)")
        model.verify(game)
        #expect(model.progress(for: game.id) != nil)
        model.stop(gameID: game.id)
        #expect(model.progress(for: game.id) == nil)
        #expect(model.status(for: game.id) == .notVerified)
        model.statuses[game.id] = .full
        #expect(model.status(for: game.id).title == "Verified")
    }

    @Test("Installed local games offer Verify Files and request local verification")
    func menuRoute() throws {
        let fixture = try SteamFixture("verify-menu")
        defer { fixture.remove() }
        let model = libraryModel(fixture, defaults: ScratchDefaults())
        #expect(GameMenu.items(for: game, in: model).contains { $0.action == .verifyFiles && $0.title == "Verify Files…" })
        GameActionRunner(model: model, open: { _ in Issue.record("Local verification must not open Steam") })
            .perform(.verifyFiles, on: game)
        #expect(model.verificationRequest == game)
    }

    @Test("All mismatch choices leave output unverified")
    func mismatchChoices() {
        let model = FixtureGameVerification()
        for choice in 0..<3 {
            model.statuses[game.id] = .full
            model.mismatch = .init(gameID: game.id, files: ["data/game.pak"])
            switch choice {
            case 0: model.retryStandard(gameID: game.id)
            case 1: model.keepAnyway(gameID: game.id)
            default: model.cancelMismatch(gameID: game.id)
            }
            #expect(model.mismatch == nil)
            #expect(model.status(for: game.id) == .notVerified)
        }
        #expect(model.retried == game.id)
    }

    @Test("Panel evidence, progress and mismatch recovery render in light and dark")
    func views() async throws {
        let model = FixtureGameVerification()
        for dark in [false, true] {
            for status in [GameVerificationStatus.notVerified, .sizes, .full] {
                model.statuses[game.id] = status
                let texts = try await renderedTexts(GameVerificationRow(game: game).environment(\.gameVerification, model),
                                                    size: CGSize(width: 324, height: 180), named: "verification-row", dark: dark)
                #expect(seen(texts, status.title))
            }
            model.verify(game)
            let progress = try await renderedTexts(GameVerificationRow(game: game).environment(\.gameVerification, model),
                                                   size: CGSize(width: 324, height: 200), named: "verification-progress", dark: dark)
            #expect(seen(progress, "Verifying files"))
            #expect(seen(progress, "Stop"))
            let mismatch = GameVerificationMismatch(gameID: game.id, files: ["data/game.pak", "bin/game.exe"])
            let texts = try await renderedTexts(GameVerificationMismatchSheet(mismatch: mismatch, verification: model),
                                                size: CGSize(width: 620, height: 380), named: "verification-mismatch", dark: dark)
            #expect(seen(texts, "Some files"), "Rendered mismatch sheet: \(texts)")
            #expect(seen(texts, "Retry with the Standard Method"))
            #expect(seen(texts, "Keep Anyway"))
            #expect(seen(texts, "Cancel"))
        }
    }
}
