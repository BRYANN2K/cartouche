// A process output log that never grows past a cap: the first half keeps the head, where the first
// failure is, and when the cap is hit the middle is dropped in favor of the tail. The buffer sits
// in memory and is flushed to disk every few MB and on finish, so the file is always a valid,
// bounded log while the process still runs.

import Foundation

public final class OutputLog: @unchecked Sendable {

    public let url: URL
    public let limit: Int64

    private let lock = NSLock()
    private var skippedBytes: Int64 = 0
    private let headLimit: Int
    private var buf = Data()
    private var unsynced = 0
    private var handle: FileHandle?

    // Bytes of process output that were dropped to stay under the cap.
    public var skipped: Int64 { lock.withLock { skippedBytes } }

    // The first failure sits early and a crash loop floods the end, so half the budget keeps the
    // head. CARTOUCHE_WINELOG_MB raises the budget for a diagnostic run.
    public static var defaultLimit: Int64 {
        let mb = ProcessInfo.processInfo.environment["CARTOUCHE_WINELOG_MB"].flatMap(Int64.init) ?? 32
        return max(mb, 1) << 20
    }

    public init?(url: URL, limit: Int64 = OutputLog.defaultLimit, headLimit: Int? = nil) {
        let headLimit = min(headLimit ?? Int(limit / 2), Int(limit / 2) - 8192)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.limit = max(limit, Int64(headLimit) + 16384)
        self.headLimit = headLimit
        self.handle = handle
    }

    public func feed(_ data: Data) {
        lock.withLock {
            buf.append(data)
            if Int64(buf.count) > limit {
                let tailLen = Int(limit) - headLimit - 4096
                var tail = buf.suffix(tailLen)
                // Start the tail on a line boundary so the log stays readable.
                if let nl = tail.firstIndex(of: 0x0A), nl + 1 < tail.count { tail = tail.suffix(from: nl + 1) }
                skippedBytes += Int64(buf.count - headLimit - tail.count)
                buf = buf.prefix(headLimit) + Data("\n… \(skippedBytes) bytes skipped …\n".utf8) + tail
            }
            unsynced += data.count
            if unsynced > 4 << 20 { flush() }
        }
    }

    private func flush() {
        guard let handle else { return }
        do {
            handle.seek(toFileOffset: 0)
            try handle.write(contentsOf: buf)
            try handle.truncate(atOffset: UInt64(buf.count))
            unsynced = 0
        } catch { self.handle = nil }
    }

    public func finish() {
        lock.withLock {
            flush()
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }
}
