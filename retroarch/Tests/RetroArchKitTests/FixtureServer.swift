import Foundation
import Network
import Synchronization

// A local HTTP server standing in for the libretro buildbot: it serves the
// files it is given on 127.0.0.1 and remembers what was asked for
final class FixtureServer: Sendable {

    private struct State {
        var files: [String: Data] = [:]
        var status: [String: Int] = [:]
        var requests: [String] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fixture-server")
    private let state = Mutex(State())

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let ready = Mutex<CheckedContinuation<Void, Error>?>(nil)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready: ready.withLock { $0?.resume(); $0 = nil }
                case .failed(let error): ready.withLock { $0?.resume(throwing: error); $0 = nil }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!
    }

    func stop() { listener.cancel() }

    func put(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }

    func fail(_ path: String, with status: Int) { state.withLock { $0.status[path] = status } }

    var requests: [String] { state.withLock { $0.requests } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.respond(connection, path: path)
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        let (body, status) = state.withLock { state -> (Data?, Int?) in
            state.requests.append(path)
            return (state.files[path], state.status[path])
        }
        let code = status ?? (body == nil ? 404 : 200)
        let payload = code == 200 ? (body ?? Data()) : Data()
        var response = Data("HTTP/1.1 \(code) X\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// Zips files the way the buildbot serves them: each at the top of the archive
func zipFixture(_ files: [String: Data], in folder: URL) throws -> Data {
    let staging = folder.appending(path: "zip-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    for (name, data) in files { try data.write(to: staging.appending(path: name)) }
    let archive = folder.appending(path: "\(UUID().uuidString).zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = staging
    zip.arguments = ["-q", archive.path] + files.keys.sorted()
    try zip.run()
    zip.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: archive) }
    return try Data(contentsOf: archive)
}

// Enough of a 64-bit Mach-O header for the core check, then filler that
// tells one build from another
func fakeCore(_ build: String) -> Data {
    Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]) + Data("fake core \(build)".utf8)
}
