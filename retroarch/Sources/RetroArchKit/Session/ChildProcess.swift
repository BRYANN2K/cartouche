import Foundation
import Synchronization

// A started RetroArch: its pipes, and a wait for its exit that can give up.
// Process is only asked for its identifier once running, which is safe from
// any thread.
final class ChildProcess: @unchecked Sendable {

    let process: Process
    private let stdinPipe: Pipe?
    private let exit = Mutex<ExitState>(ExitState())

    private struct ExitState {
        var status: Int32?
    }

    // stdout arrives here split into lines; nil marks its end
    init(
        executable: URL, arguments: [String], environment: [String: String]?,
        stderr: URL?, pipes: Bool, onLine: @escaping @Sendable (Data?) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        if pipes {
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            stdinPipe = input
            let splitter = LineSplitter(onLine)
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.finish()
                } else {
                    splitter.feed(chunk)
                }
            }
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
        }

        if let stderr {
            FileManager.default.createFile(atPath: stderr.path(percentEncoded: false), contents: nil)
            let log = try FileHandle(forWritingTo: stderr)
            process.standardError = log
            // Without --mcp-stdio, RetroArch logs to stdout
            if !pipes { process.standardOutput = log }
        } else {
            process.standardError = FileHandle.nullDevice
        }

        self.process = process
        process.terminationHandler = { [weak self] done in
            self?.exit.withLock { $0.status = done.terminationStatus }
        }
        try process.run()
    }

    var identifier: Int32 { process.processIdentifier }

    var exitStatus: Int32? { exit.withLock { $0.status } }

    func write(_ data: Data) throws {
        guard let stdinPipe else { throw MCPClientError.closed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    // True when it exited within the time. Polled, so a wait that gives up
    // leaves nothing behind.
    func waitForExit(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while exitStatus == nil {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func signal(_ sig: Int32) {
        guard exitStatus == nil else { return }
        kill(process.processIdentifier, sig)
    }
}

private final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())
    private let onLine: @Sendable (Data?) -> Void

    init(_ onLine: @escaping @Sendable (Data?) -> Void) { self.onLine = onLine }

    func feed(_ chunk: Data) {
        let lines = buffer.withLock { buffer -> [Data] in
            buffer.append(chunk)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func finish() { onLine(nil) }
}
