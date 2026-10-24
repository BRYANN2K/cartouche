import Foundation
import Testing
@testable import NotProtonApp

// The first import parks until the test lets it go; later ones answer at once.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func installed() -> Bool {
        let first = lock.withLock {
            calls += 1
            return calls == 1
        }
        guard first else { return false }
        entered.signal()
        resume.wait()
        return true
    }
}

@MainActor
@Suite("Library loading order")
struct LibraryLoadOrderTests {

    @Test("A Steam import that finishes after a newer one does not overwrite it")
    func staleLoadLoses() async throws {
        let work = try scratchDirectory("library-load-order")
        defer { try? FileManager.default.removeItem(at: work) }
        let gate = Gate()
        let importer = SteamLibraryImporter(
            files: SteamLocalFiles(userData: work.appending(path: "steam")), export: work.appending(path: "none.json"),
            isInstalled: { gate.installed() }, isRunning: { true })
        let model = LibraryModel(store: LibraryStore(folder: work), importer: importer, defaults: ScratchDefaults().defaults)

        let first = Task { await model.load() }
        try await offMain { gate.entered.wait() }
        await model.load()
        #expect(model.steam.presence == .notInstalled)

        gate.resume.signal()
        await first.value
        #expect(model.steam.presence == .notInstalled)
        #expect(!model.loading)
    }
}
