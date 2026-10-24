import Foundation
import Testing
@testable import RetroArchKit

@Suite("Game folder watcher")
struct FolderWatcherTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func changed() { lock.withLock { count += 1 } }
        var received: Bool { lock.withLock { count > 0 } }
    }

    @Test("Background stream setup still delivers file changes")
    func deliversChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cartouche-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = Events()
        let watcher = FolderWatcher { events.changed() }
        watcher.watch([root], latency: 0.05)
        defer { watcher.stop() }
        // Repeated writes cover asynchronous stream setup without assuming a fixed start time.
        for index in 0..<30 {
            try Data([UInt8(index)]).write(to: root.appending(path: "game.rom"))
            try await Task.sleep(for: .milliseconds(100))
            if events.received { break }
        }
        #expect(events.received)
        watcher.watch([])
    }
}
