import Foundation
import Synchronization

// A started RetroArch: its pipes, and a wait for its exit that can give up. Process is only asked for its identifier once running, which is safe from any thread.
final class ChildProcess: @unchecked Sendable {

    let process: Process
    private let stdinPipe: Pipe?
    private let exit = Mutex<ExitState>(ExitState())

    private struct ExitState {
        var status: Int32?
        var waiting: [CheckedContinuation<Int32, Never>] = []
    }

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
            // RetroArch can die between an isRunning check and the write: fail with EPIPE instead of SIGPIPE ending the app
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
            self?.exit.withLock { state in
                state.status = done.terminationStatus
                for waiter in state.waiting { waiter.resume(returning: done.terminationStatus) }
                state.waiting = []
            }
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

    func exited() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = exit.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiting.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

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
    private let buffer = Mutex((data: Data(), scanned: 0))
    private let onLine: @Sendable (Data?) -> Void

    init(_ onLine: @escaping @Sendable (Data?) -> Void) { self.onLine = onLine }

    func feed(_ chunk: Data) {
        let lines = buffer.withLock { state -> [Data] in
            state.data.append(chunk)
            var lines: [Data] = []
            while let newline = state.data.dropFirst(state.scanned).firstIndex(of: 0x0A) {
                lines.append(Data(state.data[state.data.startIndex..<newline]))
                state.data.removeSubrange(state.data.startIndex...newline)
                state.scanned = 0
            }
            state.scanned = state.data.count
            return lines
        }
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func finish() { onLine(nil) }
}
