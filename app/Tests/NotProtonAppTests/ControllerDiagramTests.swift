import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Controller diagram", .serialized)
@MainActor
struct ControllerDiagramTests {
    @Test("Face glyphs and added triggers follow the controller family")
    func labels() {
        #expect(PadButton.south.diagramLabel(.playStation) == "×")
        #expect(PadButton.north.diagramLabel(.playStation) == "△")
        #expect(PadButton.south.diagramLabel(.xbox) == "A")
        #expect(PadButton.leftTrigger.diagramLabel(.playStation) == "L2")
        #expect(PadButton.leftTrigger.diagramLabel(.xbox) == "LT")
        #expect(PadButton.rightTrigger.diagramLabel(.xbox) == "RT")
    }

    @Test("Live input is published only while the diagram is visible and clears on disconnect")
    func liveInput() async throws {
        let scene = try await ControlsScene("diagram-live")
        defer { scene.remove() }
        scene.pad.state = PadState(pressed: [.south, .leftTrigger])
        scene.center.tick(now: 0)
        #expect(scene.center.diagramState == .idle)
        scene.center.diagramVisible = true
        scene.center.tick(now: 1)
        #expect(scene.center.diagramState.pressed == [.south, .leftTrigger])
        scene.pad.state = nil
        scene.center.tick(now: 2)
        #expect(scene.center.diagramState == .idle)
        scene.center.dismiss()
        #expect(!scene.center.diagramVisible)
    }

    @Test("Site controller geometry and live highlights render in both appearances")
    func renders() async throws {
        for dark in [false, true] {
            for family in [PadFamily.playStation, .xbox] {
                let texts = try await renderedTexts(ControllerDiagram(family: family,
                    state: PadState(pressed: [.south, .leftTrigger, .rightTrigger]), highlighted: .north),
                    size: CGSize(width: 460, height: 310), named: "controller-diagram-\(family.rawValue)", dark: dark)
                #expect(seen(texts, "sends"))
            }
        }
    }
}
