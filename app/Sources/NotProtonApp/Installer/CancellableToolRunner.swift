// innoextract for the install engine: ProcessToolRunner's bounded run, plus a cancel() that
// terminates the running tool so Stop never waits out a long extraction.

import Foundation
import InstallerKit

final class CancellableToolRunner: ToolRunning, @unchecked Sendable {

    struct TimedOut: Error { let tool: String }

    let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(timeout: TimeInterval) { self.timeout = timeout }

    var isCancelled: Bool { lock.withLock { cancelled } }

    // Once cancelled, the running tool gets SIGTERM and every later run throws before it starts.
    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try p.run()
            process = p
        }
        defer { lock.withLock { process = nil } }
        nonisolated(unsafe) var data = Data()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
        // Polled, so a cancel returns even while a child the tool left behind still holds the pipe.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled {
                p.terminate()
                throw CancellationError()
            }
            if Date() > deadline {
                p.terminate()
                _ = done.wait(timeout: .now() + 5)
                throw TimedOut(tool: tool)
            }
        }
        p.waitUntilExit()
        if isCancelled { throw CancellationError() }
        return String(decoding: data, as: UTF8.self)
    }
}
