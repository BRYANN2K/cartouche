//// An installed game copied into Cartouche's folder, file by file so the sheet shows progress. Cancelling the task stops it.

import Foundation

enum GameCopy {

    // Returns the bytes copied; progress is reported every 8 MB or so.
    @discardableResult
    static func copy(_ source: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached { try copyFiles(source, to: target, stop: stop, progress: progress) }.value
        } onCancel: {
            stop.set()
        }
    }

    static func copyFiles(_ source: URL, to target: URL, stop: StopFlag, progress: (Int64) -> Void) throws -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path(percentEncoded: false)])
        }
        let base = source.standardizedFileURL.pathComponents.count
        var copied: Int64 = 0, reported: Int64 = 0
        for case let url as URL in walk {
            if stop.isSet { throw CancellationError() }
            let destination = target.appending(path: url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/"))
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true, values.isSymbolicLink != true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: url, to: destination)
                copied += Int64(values.fileSize ?? 0)
                if copied - reported >= 8 << 20 { progress(copied); reported = copied }
            }
        }
        return copied
    }

    static func rebase(_ file: URL, from source: URL, to target: URL) -> URL {
        let parts = file.standardizedFileURL.pathComponents, base = source.standardizedFileURL.pathComponents
        guard parts.starts(with: base) else { return file }
        return target.appending(path: parts.dropFirst(base.count).joined(separator: "/"))
    }

    // An external or removable drive: a game used in place there plays only while it is connected.
    static func isExternal(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey])
        return values?.volumeIsInternal == false || values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
