import Foundation
import Network
import RetroArchKit

// POST /mcp with a JSON-RPC body and a bearer token, loopback only; off by default, token made once, shown in Settings > Agents.
public final class MCPHTTPServer: @unchecked Sendable {

    public enum HTTPError: LocalizedError {
        case alreadyStarted
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted: "the HTTP transport is already running"
            case .failed(let detail): detail
            }
        }
    }

    // Header keys are stored lowercased.
    struct Request {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data

        var authorization: String? { headers["authorization"] }
    }

    private let handler: @Sendable (Data, MCPPeer) async -> Data
    private let token: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var boundPort: UInt16 = 0

    public let queue = DispatchQueue(label: "cartouche.mcp.http")

    public var port: UInt16 { lock.withLock { boundPort } }

    // The listener can only say "port in use" asynchronously, after start() already returned.
    public var onState: (@Sendable (String) -> Void)?

    public convenience init(token: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.init(token: token, serve: { data, _ in await handler(data) })
    }

    // Every request is its own connection: the Mcp-Session-Id given at initialize keys the peer.
    public init(token: String, serve: @escaping @Sendable (Data, MCPPeer) async -> Data) {
        self.token = token
        self.handler = serve
    }

    static let sessionHeader = "Mcp-Session-Id"

    static func peer(session: String?) -> MCPPeer { MCPPeer(transport: "HTTP", session: session ?? "") }

    static func isInitialize(_ body: Data) -> Bool {
        (try? JSONDecoder().decode(JSONValue.self, from: body))?["method"]?.string == "initialize"
    }

    // Loopback only: the listener never sees packets from another interface.
    public static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    public func start(port: UInt16) throws {
        try lock.withLock {
            guard listener == nil else { throw HTTPError.alreadyStarted }
            let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
            let listener = try NWListener(using: Self.parameters(), on: endpoint)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port {
                        lock.withLock { boundPort = port.rawValue }
                    }
                    onState?("running")
                case .waiting(let error), .failed(let error):
                    onState?(error.localizedDescription)
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
            buffers = [:]
            boundPort = 0
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state, let self { self.drop(id) }
            if case .cancelled = state, let self { self.drop(id) }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func drop(_ id: UUID) {
        lock.withLock {
            connections[id]?.cancel()
            connections[id] = nil
            buffers[id] = nil
        }
    }

    // One request per connection keeps state simple.
    private func receive(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = lock.withLock { buffers[id] ?? Data() }
            if let data { buffer.append(data) }
            do {
                if let request = try Self.request(in: buffer) {
                    Task {
                        let reply = await self.answer(request)
                        connection.send(content: reply, completion: .contentProcessed { _ in
                            self.drop(id)
                        })
                    }
                    return
                }
            } catch {
                // Bad framing (negative or malformed Content-Length, chunked): answer 400 rather than wait for bytes that never make a whole request.
                connection.send(content: Self.response(400, #"{"error":"bad request"}"#),
                                completion: .contentProcessed { [weak self] _ in self?.drop(id) })
                return
            }
            lock.withLock { buffers[id] = buffer }
            if buffer.count > 1 << 22 || complete || error != nil {
                self.drop(id)
                return
            }
            self.receive(on: connection, id: id)
        }
    }

    // MARK: The request/answer

    private func answer(_ request: Request) async -> Data {
        // A browser on another site could reach the loopback port through DNS rebinding: Host must name loopback, and a sent Origin must too.
        guard Self.acceptsHost(request) else {
            return Self.response(403, #"{"error":"forbidden"}"#)
        }
        guard Self.authorized(request.authorization, token: token) else {
            return Self.response(401, #"{"error":"unauthorized"}"#)
        }
        guard request.target.split(separator: "?").first.map(String.init) == "/mcp" else {
            return Self.response(404, #"{"error":"not found"}"#)
        }
        guard request.method == "POST" else {
            return Self.response(405, #"{"error":"method not allowed"}"#)
        }
        var session = request.headers[Self.sessionHeader.lowercased()].map { String($0.prefix(128)) }
        var extra: [String: String] = [:]
        if Self.isInitialize(request.body) {
            session = UUID().uuidString
            extra[Self.sessionHeader] = session
        }
        let reply = await handler(request.body, Self.peer(session: session))
        guard !reply.isEmpty else {
            return Self.response(202, "", headers: extra)
        }
        return Self.response(200, reply, type: "application/json", headers: extra)
    }

    static func response(_ status: Int, _ body: Data, type: String = "application/json",
                         headers: [String: String] = [:]) -> Data {
        response(status, body.isEmpty ? "" : String(decoding: body, as: UTF8.self), type: type, headers: headers)
    }

    static func response(_ status: Int, _ body: String, type: String = "application/json",
                         headers: [String: String] = [:]) -> Data {
        let phrases = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                       403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(status) \(phrases[status] ?? "Error")\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        if !body.isEmpty {
            head += "Content-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    // Compared at constant cost so a guessing token learns nothing from how far in it differs.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header else { return false }
        let expected = "Bearer \(token)"
        var difference = header.utf8.count ^ expected.utf8.count
        for (a, b) in zip(header.utf8, expected.utf8) { difference |= Int(a ^ b) }
        return difference == 0
    }

    static func acceptsHost(_ request: Request) -> Bool {
        func loopback(_ value: String) -> Bool {
            var host = value
            if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex)..<end])
            } else if let colon = host.firstIndex(of: ":") {
                host = String(host[..<colon])
            }
            return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        }
        guard let host = request.headers["host"], loopback(host) else { return false }
        if let origin = request.headers["origin"] {
            guard let url = URL(string: origin), let name = url.host, loopback(name)
            else { return false }
        }
        return true
    }

    // Nil until the whole request is buffered; throws on bad framing so the caller answers 400 instead of waiting on a size that never arrives.
    static func request(in buffer: Data) throws -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.split(separator: " ", maxSplits: 2), first.count >= 2 else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            throw HTTPError.failed("chunked requests are not supported")
        }
        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), (0...(1 << 22)).contains(value) else {
                throw HTTPError.failed("bad Content-Length")
            }
            length = value
        } else {
            length = 0
        }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(first[0]), target: String(first[1]), headers: headers,
            body: Data(body.prefix(length)))
    }
}
