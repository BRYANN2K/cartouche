// legendary, gogdl+comet and nile, pinned by SHA-256 in store-clients.json; nothing runs before a match.

import Foundation

enum StoreClient: String, Codable, CaseIterable, Sendable {
    case legendary, gogdl, comet, nile

    var name: String { rawValue }
}

struct StoreClientManifest: Codable, Sendable, Equatable {

    static let format = 1

    struct Pin: Codable, Sendable, Equatable {
        let client: StoreClient
        let version: String
        let license: String
        let source: URL
        let url: URL
        let size: Int64
        let sha256: String

        var file: String { url.lastPathComponent }
    }

    let format: Int
    let revision: Int
    let clients: [Pin]

    func pin(_ client: StoreClient) -> Pin? { clients.first { $0.client == client } }

    struct Invalid: Error, Equatable, CustomStringConvertible {
        let problems: [String]
        var description: String { problems.joined(separator: "; ") }
    }

    // Licenses that allow Cartouche to download and run the client for the user
    static let allowedLicenses: Set<String> = ["GPL-3.0", "Apache-2.0", "MIT"]

    static func read(_ data: Data) throws -> StoreClientManifest {
        let manifest = try JSONDecoder().decode(StoreClientManifest.self, from: data)
        let problems = manifest.problems()
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        return manifest
    }

    func problems() -> [String] {
        var found: [String] = []
        if format != Self.format { found.append("format \(format) is not \(Self.format)") }
        for client in StoreClient.allCases where pin(client) == nil { found.append("\(client.rawValue) is not pinned") }
        var seen: Set<StoreClient> = []
        for pin in clients {
            let at = "client \(pin.client.rawValue)"
            if !seen.insert(pin.client).inserted { found.append("\(at) is listed twice") }
            for url in [pin.url, pin.source] where url.scheme != "https" || !RunnerManifest.allowedHosts.contains(url.host() ?? "") {
                found.append("\(at): \(url.absoluteString) is not an https URL on github.com")
            }
            if !pin.url.path().hasPrefix(pin.source.path() + "/releases/download/") {
                found.append("\(at): \(pin.url.absoluteString) is not a release of \(pin.source.absoluteString)")
            }
            if pin.size <= 0 { found.append("\(at): size \(pin.size)") }
            if !RunnerManifest.isSHA256(pin.sha256) { found.append("\(at): \(pin.sha256) is not a SHA-256") }
            if !Self.allowedLicenses.contains(pin.license) { found.append("\(at): license \(pin.license) is not allowed") }
        }
        return found
    }

    static func bundled() throws -> StoreClientManifest {
        guard let url = Bundle.module.url(forResource: "store-clients", withExtension: "json") else {
            throw Invalid(problems: ["store-clients.json is not in the app"])
        }
        return try read(Data(contentsOf: url))
    }
}

// Memoizes files whose SHA-256 matched their pin, keyed by (size, mtime, inode).
final class PinChecks: @unchecked Sendable {
    struct Stamp: Equatable {
        var size: Int64
        var modified: Date
        var inode: UInt64
    }

    private let lock = NSLock()
    private var verified: [String: (stamp: Stamp, sha256: String)] = [:]

    func known(_ path: String, stamp: Stamp, sha256: String) -> Bool {
        lock.withLock { verified[path]?.stamp == stamp && verified[path]?.sha256 == sha256 }
    }

    func remember(_ path: String, stamp: Stamp, sha256: String) {
        lock.withLock { verified[path] = (stamp, sha256) }
    }
}

struct StoreClientFiles: Sendable {

    var root: URL
    var downloads: URL
    var manifest: StoreClientManifest?
    var overrides: [StoreClient: URL] = [:]
    var session: URLSession = PinnedDownload.session
    let checks = PinChecks()

    init(root: URL, downloads: URL, manifest: StoreClientManifest? = try? .bundled()) {
        self.root = root
        self.downloads = downloads
        self.manifest = manifest
    }

    func location(_ client: StoreClient) -> URL? {
        if let override = overrides[client] { return override }
        guard let pin = manifest?.pin(client) else { return nil }
        return root.appending(path: "\(client.rawValue)-\(pin.version)", directoryHint: .isDirectory)
            .appending(path: client.rawValue)
    }

    // Pinned file re-checked by size and SHA-256 each run; a changed file is fetched again.
    func isReady(_ client: StoreClient) -> Bool {
        if let override = overrides[client] { return FileManager.default.isExecutableFile(atPath: override.path(percentEncoded: false)) }
        guard let pin = manifest?.pin(client), let file = location(client) else { return false }
        return matches(file, pin)
    }

    func matches(_ file: URL, _ pin: StoreClientManifest.Pin) -> Bool {
        let path = file.path(percentEncoded: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size == pin.size else { return false }
        let stamp = PinChecks.Stamp(size: size, modified: attrs[.modificationDate] as? Date ?? .distantPast,
                                    inode: (attrs[.systemFileNumber] as? UInt64) ?? 0)
        if checks.known(path, stamp: stamp, sha256: pin.sha256) { return true }
        guard Digest.sha256IfPresent(file) == pin.sha256 else { return false }
        checks.remember(path, stamp: stamp, sha256: pin.sha256)
        return true
    }

    func ensure(_ client: StoreClient, report: @Sendable (PinnedDownload.Progress) -> Void = { _ in }) async throws -> URL {
        if let override = overrides[client] { return override }
        let step = String(localized: "Download \(client.name)")
        guard let pin = manifest?.pin(client), let file = location(client) else {
            throw StepFailure(step: step, detail: String(localized: "\(client.name) is not pinned in this version of Cartouche."))
        }
        if matches(file, pin) { return file }
        try? FileManager.default.removeItem(at: file)
        let fetched = try await PinnedDownload.obtain(
            file: pin.file, sha256: pin.sha256, bases: [pin.url.deletingLastPathComponent()],
            into: downloads, step: step, from: "GitHub", session: session, report: report)
        defer { try? FileManager.default.removeItem(at: fetched) }
        guard matches(fetched, pin) else {
            throw StepFailure(step: step, detail: String(localized: "Something is wrong with the downloaded files. Please check for a Cartouche update."))
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(file, from: fetched, step: step)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }
}

struct ClientCommand: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
}

struct ClientOutput: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }
}

enum ClientProcess {

    static func run(_ command: ClientCommand, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ClientOutput {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        if let directory = command.currentDirectory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
        let capture = PipeCapture(out: out, err: err, onLine: onLine)
        try process.run()

        return await withTaskCancellationHandler {
            var status: Int32 = -1
            for await code in exited.stream { status = code }
            capture.finish()
            return ClientOutput(status: status, stdout: capture.stdout, stderr: capture.stderr)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // Reads the pipes as their data lands instead of waiting for end-of-file: a process
    // whose children keep running after it exits (EA's installer leaves the client and
    // its service up) holds the write ends open forever — the exit status is the real end
    // of the run, not the pipes' EOF.
    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let out: Pipe
        private let err: Pipe
        private let onLine: @Sendable (String) -> Void
        private var stdoutData = Data()
        private var stderrData = Data()
        private var tail = Data()
        private var eofs = 0

        init(out: Pipe, err: Pipe, onLine: @escaping @Sendable (String) -> Void) {
            self.out = out
            self.err = err
            self.onLine = onLine
            out.fileHandleForReading.readabilityHandler = { [weak self] in self?.feed($0.availableData, err: false) }
            err.fileHandleForReading.readabilityHandler = { [weak self] in self?.feed($0.availableData, err: true) }
        }

        private func feed(_ data: Data, err: Bool) {
            var lines: [String] = []
            lock.withLock {
                if data.isEmpty {
                    eofs |= err ? 2 : 1
                    return
                }
                if err {
                    stderrData.append(data)
                    tail.append(data)
                    while let nl = tail.firstIndex(of: 0x0A) {
                        lines.append(String(decoding: tail[..<nl], as: UTF8.self))
                        tail = tail.subdata(in: tail.index(after: nl)..<tail.endIndex)
                    }
                } else {
                    stdoutData.append(data)
                }
            }
            for line in lines { onLine(line) }
        }

        // EOF on both ends settles it at once; a straggler's tail gets a short grace.
        func finish() {
            let deadline = Date().addingTimeInterval(2)
            while lock.withLock({ eofs != 3 }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let rest = lock.withLock { () -> String? in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                return tail.isEmpty ? nil : String(decoding: tail, as: UTF8.self)
            }
            if let rest { onLine(rest) }
        }

        var stdout: String { lock.withLock { String(decoding: stdoutData, as: UTF8.self) } }
        var stderr: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }
    }
}

enum ClientLog {
    static func lastError(_ log: String) -> String? {
        let markers = ["ERROR: ", "CRITICAL: ", "FATAL: "]
        for line in log.split(whereSeparator: \.isNewline).reversed() {
            for marker in markers {
                if let range = line.range(of: marker) { return String(line[range.upperBound...]) }
            }
        }
        return nil
    }
}

// legendary, gogdl and nile print "= Progress: 12.34 ..." while they download
enum ClientProgress {
    static func fraction(_ line: String) -> Double? {
        guard let range = line.range(of: "= Progress: ") else { return nil }
        let number = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard let percent = Double(number) else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}
