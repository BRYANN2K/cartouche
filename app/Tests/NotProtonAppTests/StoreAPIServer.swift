import Foundation
import Network
import Synchronization

// A local HTTP server on 127.0.0.1 standing in for GitHub releases and the
// stores' web APIs: it serves what it is given, by path and query, and keeps
// each request line with its Authorization header
final class StoreAPIServer: Sendable {

    struct Request: Sendable, Equatable {
        let path: String
        let authorization: String?
    }

    private struct State {
        var files: [String: Data] = [:]
        var status: [String: Int] = [:]
        var requests: [Request] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "store-api-server")
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
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    func stop() { listener.cancel() }

    func put(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }
    func put(_ path: String, json: String) { put(path, Data(json.utf8)) }
    func fail(_ path: String, with status: Int) { state.withLock { $0.status[path] = status } }

    var requests: [Request] { state.withLock { $0.requests } }

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
            let lines = head.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let auth = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
                .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
            self.respond(connection, request: Request(path: path, authorization: auth))
        }
    }

    private func respond(_ connection: NWConnection, request: Request) {
        let (body, status) = state.withLock { state -> (Data?, Int?) in
            state.requests.append(request)
            return (state.files[request.path], state.status[request.path])
        }
        let code = status ?? (body == nil ? 404 : 200)
        let payload = code == 200 ? (body ?? Data()) : Data()
        var response = Data("HTTP/1.1 \(code) X\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
