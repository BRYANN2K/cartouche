import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner choices")
struct RunnerChoicesTests {
    @Test("Only the latest Cartouche revision is downloadable; store installs also offer WineHQ")
    func downloads() {
        let manifest = RunnerManifest.current()
        let own = manifest.builds.first { $0.origin == .cartouche }!
        let installed = Runner(id: own.id, kind: .wineBuild, version: own.version,
                               displayVersion: own.displayVersion, flavors: [.rosetta],
                               state: .ready, build: nil, source: nil, isInstalled: true)
        let steam = RunnerChoices.downloads(manifest: manifest, installed: [installed], steam: true)
        #expect(steam.isEmpty)
        #expect(steam.allSatisfy { $0.origin == .cartouche && $0.id != own.id && $0.isPinned })
        let fresh = RunnerChoices.downloads(manifest: manifest, installed: [], steam: true)
        #expect(fresh.map(\.id) == [own.id])
        let stores = RunnerChoices.downloads(manifest: manifest, installed: [installed], steam: false)
        #expect(stores.contains { $0.origin == .winehq })
        #expect(!stores.contains { $0.id == own.id })
    }

    @Test("Same-version runner revisions have different selection labels")
    func revisions() {
        let first = RunnerChoices.title(id: "wine-crossover-26.3.0-1", name: "Cartouche Wine", version: "26.3")
        let second = RunnerChoices.title(id: "wine-crossover-26.3.0-2", name: "Cartouche Wine", version: "26.3")
        #expect(first == "Cartouche Wine 26.3.0-1")
        #expect(first != second)
        #expect(RunnerChoices.title(id: "wine-stable-11.0_1", name: "Wine", version: "11.0") == "Wine 11.0")
    }
}
