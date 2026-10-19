import Foundation
import Network

// The optional HTTP transport: POST /mcp with a JSON-RPC body and a bearer
// token, on loopback only. Off by default; the token is made once and shown
// in Settings > Agents.
public final class MCPHTTPServer: @unchecked Sendable {

    public enum HTTPError: LocalizedError {
        case notStarted
        case alreadyStarted
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notStarted: "the HTTP transport is not running"
            case .alreadyStarted: "the HTTP transport is already running"
            case .failed(let detail): detail
            }
        }
    }

    // One request: method, target, headers (lowercased keys) and body.
    struct Request {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data

        var authorization: String? { headers["authorization"] }
    }

    private let handler: @Sendable (Data) async -> Data
    private let token: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]

    public let queue = DispatchQueue(label: "cartouche.mcp.http")

    public private(set) var port: UInt16 = 0

    public init(token: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.token = token
        self.handler = handler
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
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let self, let port = listener.port {
                    self.port = port.rawValue
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
            port = 0
        }
    }

    public var isRunning: Bool { lock.withLock { listener != nil } }

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

    // Reads until the request is complete (headers + Content-Length body),
    // answers, then closes: one request per connection keeps state simple.
    private func receive(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = lock.withLock { buffers[id] ?? Data() }
            if let data { buffer.append(data) }
            if let request = Self.request(in: buffer) {
                Task {
                    let reply = await self.answer(request)
                    connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
                        self?.drop(id)
                    })
                }
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
        // The token is checked before the route, so a wrong one always says 401.
        guard request.authorization == "Bearer \(token)" else {
            return Self.response(401, #"{"error":"unauthorized"}"#)
        }
        guard request.target.split(separator: "?").first.map(String.init) == "/mcp" else {
            return Self.response(404, #"{"error":"not found"}"#)
        }
        guard request.method == "POST" else {
            return Self.response(405, #"{"error":"method not allowed"}"#)
        }
        let reply = await handler(request.body)
        guard !reply.isEmpty else {
            return Self.response(202, "")
        }
        return Self.response(200, reply, type: "application/json")
    }

    static func response(_ status: Int, _ body: Data, type: String = "application/json") -> Data {
        response(status, body.isEmpty ? "" : String(decoding: body, as: UTF8.self), type: type)
    }

    static func response(_ status: Int, _ body: String, type: String = "application/json") -> Data {
        let phrases = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                       404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(status) \(phrases[status] ?? "Error")\r\n"
        if !body.isEmpty {
            head += "Content-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    // Nil until the buffer holds the whole request.
    static func request(in buffer: Data) -> Request? {
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
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(first[0]), target: String(first[1]), headers: headers,
            body: Data(body.prefix(length)))
    }
}
