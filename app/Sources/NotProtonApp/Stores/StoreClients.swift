// The open-source clients Cartouche drives for Epic Games, GOG and Amazon Games:
// legendary, gogdl with comet, and nile. Each is pinned by version, size and
// SHA-256 in store-clients.json and downloaded from its own GitHub release the
// first time a store needs it. Nothing runs before the file matches its pin.

import Foundation

enum StoreClient: String, Codable, CaseIterable, Sendable {
    case legendary, gogdl, comet, nile

    // Product names, not translated
    var name: String { rawValue }
}

struct StoreClientManifest: Codable, Sendable, Equatable {

    static let format = 1

    struct Pin: Codable, Sendable, Equatable {
        let client: StoreClient
        let version: String
        // SPDX identifier, from the repository's license file
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

// Where each client lives once downloaded, and the download itself
struct StoreClientFiles: Sendable {

    // stores/clients/<client>-<version>/<client>
    var root: URL
    var downloads: URL
    var manifest: StoreClientManifest?
    // Tests point a client at a stand-in executable
    var overrides: [StoreClient: URL] = [:]
    var session: URLSession = PinnedDownload.session

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

    // The pinned file, checked by size and SHA-256 each time: a changed file is
    // deleted and fetched again
    func isReady(_ client: StoreClient) -> Bool {
        if let override = overrides[client] { return FileManager.default.isExecutableFile(atPath: override.path(percentEncoded: false)) }
        guard let pin = manifest?.pin(client), let file = location(client) else { return false }
        return Self.matches(file, pin)
    }

    static func matches(_ file: URL, _ pin: StoreClientManifest.Pin) -> Bool {
        let path = file.path(percentEncoded: false)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size == pin.size
        else { return false }
        return Digest.sha256IfPresent(file) == pin.sha256
    }

    func ensure(_ client: StoreClient, report: @Sendable (PinnedDownload.Progress) -> Void = { _ in }) async throws -> URL {
        if let override = overrides[client] { return override }
        let step = String(localized: "Download \(client.name)")
        guard let pin = manifest?.pin(client), let file = location(client) else {
            throw StepFailure(step: step, detail: String(localized: "\(client.name) is not pinned in this version of Cartouche."))
        }
        if Self.matches(file, pin) { return file }
        try? FileManager.default.removeItem(at: file)
        let fetched = try await PinnedDownload.obtain(
            file: pin.file, sha256: pin.sha256, bases: [pin.url.deletingLastPathComponent()],
            into: downloads, step: step, from: "GitHub", session: session, report: report)
        defer { try? FileManager.default.removeItem(at: fetched) }
        guard Self.matches(fetched, pin) else {
            throw StepFailure(step: step, detail: String(localized: "Something is wrong with the downloaded files. Please check for a Cartouche update."))
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(file, from: fetched, step: step)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }
}

// One run of a client: its arguments and the environment it gets, never the app's own
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

// Runs a client and hands each line it writes to stderr to onLine, where the
// clients print their progress. Cancelling the task ends the client.
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
        try process.run()

        // Both pipes are read to their end, so nothing written just before the exit is lost
        return try await withTaskCancellationHandler {
            async let stdout = Self.drain(out.fileHandleForReading)
            async let stderr = Self.lines(err.fileHandleForReading, onLine: onLine)
            var status: Int32 = -1
            for await code in exited.stream { status = code }
            return ClientOutput(status: status, stdout: try await stdout, stderr: try await stderr)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func drain(_ handle: FileHandle) async throws -> String {
        try await Task.detached {
            String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        }.value
    }

    // A carriage return also ends a line, as progress bars use it
    private static func lines(_ handle: FileHandle, onLine: @escaping @Sendable (String) -> Void) async throws -> String {
        try await Task.detached {
            var all: [String] = []
            for try await line in handle.bytes.lines {
                all.append(line)
                onLine(line)
            }
            return all.joined(separator: "\n")
        }.value
    }
}

enum ClientLog {
    // The clients log "[cli] ERROR: Game is out of date"; this reads "Game is out of date"
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
