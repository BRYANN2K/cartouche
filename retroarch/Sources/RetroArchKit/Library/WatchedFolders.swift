import CoreServices
import Foundation

// What Cartouche does with the user's game folders, in folders.json in its
// RetroArch folder. The folder list itself is the app's (Settings > Library,
// onboarding). Cartouche reads those folders and never writes into them.
public struct WatchedFolders: Codable, Sendable, Equatable {
    public var addAutomatically = true

    public init() {}

    public static func file(_ paths: RetroArchPaths) -> URL { paths.root.appending(path: "folders.json") }

    public static func load(_ paths: RetroArchPaths) -> WatchedFolders {
        (try? Data(contentsOf: file(paths))).flatMap { try? JSONDecoder().decode(WatchedFolders.self, from: $0) } ?? WatchedFolders()
    }

    public func save(_ paths: RetroArchPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file(paths), options: .atomic)
    }
}

// Calls back when anything changes under the watched folders, through
// FSEvents, at most once per latency. A folder on a disk that is not
// connected is watched from when it appears.
public final class FolderWatcher: @unchecked Sendable {

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "cartouche.game-folders")
    private let changed: @Sendable () -> Void

    public init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    public func watch(_ folders: [URL], latency: TimeInterval = 1) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, folders.map { $0.path(percentEncoded: false) } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        lock.withLock { stream = created }
    }

    public func stop() {
        let old = lock.withLock { () -> FSEventStreamRef? in
            defer { stream = nil }
            return stream
        }
        guard let old else { return }
        FSEventStreamStop(old)
        FSEventStreamInvalidate(old)
        FSEventStreamRelease(old)
    }

    deinit { stop() }
}
