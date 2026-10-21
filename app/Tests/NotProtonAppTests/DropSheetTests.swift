import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Drop sheet", .serialized)
@MainActor
struct DropSheetTests {

    private func render(_ phase: DropPhase, named name: String) async throws -> [String] {
        let model = DropModel(classifier: FixtureDropClassifier(result: DropFixtures.installer))
        model.phase = phase
        if case .result(.installedGame(let game)) = phase { model.chosenExe = game.executables.first }
        var texts: [String] = []
        for dark in [false, true] {
            texts = try await renderedTexts(DropSheet(model: model).environment(\.glassMode, .classic),
                                            size: CGSize(width: 560, height: 620), named: "drop-\(name)", dark: dark)
        }
        return texts
    }

    @Test("The unified entry offers automatic detection and an unrestricted chooser")
    func entry() async throws {
        let texts = try await renderedTexts(AddGamesDropSheet(add: { _ in }),
                                            size: CGSize(width: 560, height: 360), named: "add-games-unified", dark: true)
        #expect(seen(texts, "Add Games"))
        #expect(seen(texts, "Drop a game, an installer, an archive or ROMs"))
        #expect(seen(texts, "Choose"))
        #expect(!seen(texts, "Windows Games"))
        #expect(!seen(texts, "Console Games"))
        let model = DropModel()
        model.start([URL(filePath: "/tmp/game.zip")])
        #expect(model.phase == .result(.failed(.detectionUnavailable)))
        let unavailable = try await render(.result(.failed(.detectionUnavailable)), named: "unavailable")
        #expect(seen(unavailable, "Game detection is unavailable"))
    }

    @Test("Detecting, then extracting with the file name and the bytes")
    func detecting() async throws {
        #expect(seen(try await render(.detecting(nil), named: "detecting"), "Looking at what you dropped"))
        let texts = try await render(.detecting(DropFixtures.extracting), named: "extracting")
        #expect(seen(texts, "Chrono Trigger Collection.7z"))
        #expect(seen(texts, "Cancel"))
    }

    @Test("Each result has one main action")
    func results() async throws {
        #expect(seen(try await render(.result(DropFixtures.installer), named: "installer"), "Continue"))
        let game = try await render(.result(DropFixtures.installedGame), named: "installed-game")
        #expect(seen(game, "Add to Library"))
        #expect(seen(game, "On an external drive"))
        let roms = try await render(.result(DropFixtures.roms), named: "roms")
        #expect(seen(roms, "Add 4 Games"))
        #expect(seen(roms, "Not recognized"))
        #expect(seen(try await render(.result(DropFixtures.mixed), named: "mixed"), "Several kinds of games"))
    }

    @Test("Failures say what happened and offer another file")
    func failures() async throws {
        let wanted = ["needs a password", "is damaged", "kind of archive", "No game found"]
        for (n, failure) in DropFixtures.failures.enumerated() {
            let texts = try await render(.result(failure), named: "failed-\(n)")
            #expect(seen(texts, wanted[n]))
            #expect(seen(texts, "Choose Another File"))
        }
    }

    @Test("A classifier's result replaces the detecting step")
    func classifies() async throws {
        let model = DropModel(classifier: FixtureDropClassifier(result: DropFixtures.roms))
        model.start([URL(filePath: "/ROMs")])
        #expect(model.isPresented)
        for _ in 0..<50 where model.phase.map({ if case .result = $0 { false } else { true } }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.phase == .result(DropFixtures.roms))
        model.cancel()
        #expect(!model.isPresented)
    }
}
