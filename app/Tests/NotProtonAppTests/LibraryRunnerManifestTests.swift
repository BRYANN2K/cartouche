import Foundation
import Testing
@testable import NotProtonApp

@MainActor
@Suite("The library's install runners read the manifest loaded with the runners")
struct LibraryRunnerManifestTests {

    @Test("installRunners orders by the cached manifest and never reads one itself")
    func cachedManifestOrdersInstallRunners() throws {
        let work = try scratchDirectory("library-manifest")
        defer { try? FileManager.default.removeItem(at: work) }
        let model = LibraryModel(store: LibraryStore(folder: work), defaults: ScratchDefaults().defaults)
        let winehq = InstallPrefixTests.freeWine("wine-stable-11.0_1")
        let ours = InstallPrefixTests.freeWine("wine-crossover-26.3.0-1")
        model.runners = [winehq, ours]
        #expect(model.installRunners.map(\.id) == [winehq.id, ours.id])
        model.runnerManifest = InstallPrefixTests.manifest(origin: .cartouche)
        #expect(model.installRunners.map(\.id) == [ours.id, winehq.id])
    }

    @Test("A backend download rewrites Steam's tool list off the main actor, then reloads the runners")
    func backendDownloadSyncsTools() async {
        let order = Order()
        await BackendDownloadsSection.afterInstall(syncTools: { order.add(Thread.isMainThread ? "sync on main" : "sync") },
                                                   reload: { order.add("reload") })
        #expect(order.steps == ["sync", "reload"])
        await BackendDownloadsSection.afterInstall(syncTools: { throw CocoaError(.fileWriteNoPermission) },
                                                   reload: { order.add("reload") })
        #expect(order.steps == ["sync", "reload", "reload"])
    }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []
    var steps: [String] { lock.withLock { made } }
    func add(_ step: String) { lock.withLock { made.append(step) } }
}
