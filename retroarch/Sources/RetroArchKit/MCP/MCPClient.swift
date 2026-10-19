import Foundation

public enum MCPClientError: Error, Equatable, Sendable {
    case closed
    case timedOut(String)
    case malformed(String)
    case rpc(code: Int, message: String)
}

// One tool as tools/list describes it
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        description = json["description"]?.string ?? ""
        inputSchema = json["inputSchema"] ?? [:]
        readOnly = json["annotations"]?["readOnlyHint"]?.bool ?? false
        destructive = json["annotations"]?["destructiveHint"]?.bool ?? true
    }

    public var parameters: [String: JSONValue] { inputSchema["properties"]?.object ?? [:] }

    public var required: Set<String> {
        Set(inputSchema["required"]?.array?.compactMap(\.string) ?? [])
    }
}

public struct ToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public var images: [Data]
    public var structured: JSONValue?

    init(_ json: JSONValue) {
        var texts: [String] = []
        var images: [Data] = []
        for item in json["content"]?.array ?? [] {
            switch item["type"]?.string {
            case "text": texts.append(item["text"]?.string ?? "")
            case "image":
                if let data = item["data"]?.string.flatMap({ Data(base64Encoded: $0) }) { images.append(data) }
            default: break
            }
        }
        text = texts.joined(separator: "\n")
        self.images = images
        isError = json["isError"]?.bool ?? false
        structured = json["structuredContent"]
    }
}

// JSON-RPC over one line per message, as RetroArch's --mcp-stdio speaks it
public actor MCPClient {

    public static let protocolVersion = "2025-06-18"

    private let send: @Sendable (Data) throws -> Void
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var isClosed = false
    private var logLines: [String] = []

    public init(send: @escaping @Sendable (Data) throws -> Void) {
        self.send = send
    }

    // The last lines RetroArch sent as notifications/message, for a failure report
    public var recentLog: [String] { logLines }

    public func initialize(client: String, version: String) async throws -> JSONValue {
        let result = try await request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": .string(client), "version": .string(version)],
        ])
        try notify("notifications/initialized")
        return result
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list")
        guard let tools = result["tools"]?.array else { throw MCPClientError.malformed("tools/list has no tools") }
        return tools.compactMap(MCPTool.init)
    }

    public func call(_ name: String, _ arguments: [String: JSONValue] = [:], timeout: Duration = .seconds(12))
        async throws -> ToolResult
    {
        let result = try await request(
            "tools/call", params: ["name": .string(name), "arguments": .object(arguments)], timeout: timeout)
        return ToolResult(result)
    }

    public func request(_ method: String, params: JSONValue = [:], timeout: Duration = .seconds(12))
        async throws -> JSONValue
    {
        guard !isClosed else { throw MCPClientError.closed }
        let id = nextID
        nextID += 1
        let line = try Self.encode([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, method: method)
            }
        }
    }

    public func notify(_ method: String, params: JSONValue = [:]) throws {
        guard !isClosed else { throw MCPClientError.closed }
        try send(Self.encode(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    // Fed by whoever reads the server's output, one line at a time
    public func receive(_ line: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        guard let id = message["id"]?.int else {
            if message["method"]?.string == "notifications/message",
               let text = message["params"]?["data"].map(Self.describe)
            {
                logLines.append(text)
                if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
            }
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: MCPClientError.rpc(
                code: error["code"]?.int ?? 0, message: error["message"]?.string ?? ""))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    // The server went away: nothing still waiting will be answered
    public func close() {
        isClosed = true
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: MCPClientError.closed) }
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: MCPClientError.timedOut(method))
    }

    static func encode(_ message: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    private static func describe(_ value: JSONValue) -> String {
        if let s = value.string { return s }
        return (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? ""
    }
}
