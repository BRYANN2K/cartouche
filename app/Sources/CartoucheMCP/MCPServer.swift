import Foundation
import RetroArchKit

// The MCP wire protocol Cartouche speaks, same line-delimited JSON-RPC as the
// RetroArchKit client. Versioned to what the client side already uses.
public enum MCP {
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "cartouche"
}

public struct MCPToolInfo: Sendable, Equatable {
    public var name: String
    public var detail: String
    public var schema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    public init(name: String, detail: String, schema: JSONValue, readOnly: Bool = true, destructive: Bool = false) {
        self.name = name
        self.detail = detail
        self.schema = schema
        self.readOnly = readOnly
        self.destructive = destructive
    }

    var json: JSONValue {
        [
            "name": .string(name),
            "description": .string(detail),
            "inputSchema": schema,
            "annotations": [
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
            ],
        ]
    }
}

public enum MCPError: LocalizedError {
    case methodNotFound(String)
    case invalidParams(String)

    public var errorDescription: String? {
        switch self {
        case .methodNotFound(let detail), .invalidParams(let detail): detail
        }
    }
}

// What the app offers over MCP: the tools, and who answers them. The tool
// implementations live in the app; the helper and the HTTP server only carry
// the bytes.
public protocol MCPHandling: Sendable {
    var serverVersion: String { get }
    // The client name from the last initialize, for the action log.
    var clientName: String { get }
    func initialize(client: String) async
    func tools(client: String) async -> [MCPToolInfo]
    // The whole tools/call result payload (content, structuredContent, isError)
    // or a thrown MCPError for a JSON-RPC error.
    func callTool(_ name: String, arguments: JSONValue, client: String) async throws -> JSONValue
    func resources(client: String) async -> [JSONValue]
    func readResource(_ uri: String, client: String) async throws -> String
}

public extension MCPHandling {
    func resources(client: String) async -> [JSONValue] { [] }
    func readResource(_ uri: String, client: String) async throws -> String {
        throw MCPError.methodNotFound("unknown resource \(uri)")
    }
}

// Turns one JSON-RPC message into its reply. Nil means the message was a
// notification and gets no reply, per JSON-RPC.
public struct MCPServer: Sendable {

    public let handler: any MCPHandling

    public init(handler: any MCPHandling) { self.handler = handler }

    public func handle(_ message: JSONValue) async -> JSONValue? {
        if case .array(let batch) = message {
            var out: [JSONValue] = []
            for item in batch { if let reply = await handle(item) { out.append(reply) } }
            return out.isEmpty ? nil : .array(out)
        }
        guard let method = message["method"]?.string else {
            return message["id"] == nil ? nil : Self.reply(to: message, error: (-32600, "request without method"))
        }
        switch method {
        case "initialize":
            let client = message["params"]?["clientInfo"]?["name"]?.string ?? "agent"
            await handler.initialize(client: client)
            return Self.reply(to: message, result: [
                "protocolVersion": .string(MCP.protocolVersion),
                "capabilities": [
                    "tools": ["listChanged": .bool(false)],
                    "resources": ["subscribe": .bool(false), "listChanged": .bool(false)],
                ],
                "serverInfo": ["name": .string(MCP.serverName), "version": .string(handler.serverVersion)],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case let m where m.hasPrefix("notifications/"):
            return nil
        case "ping":
            return Self.reply(to: message, result: [:])
        case "tools/list":
            let tools = await handler.tools(client: handler.clientName)
            return Self.reply(to: message, result: ["tools": .array(tools.map(\.json))])
        case "tools/call":
            guard let name = message["params"]?["name"]?.string else {
                return Self.reply(to: message, error: (-32602, "tools/call without a name"))
            }
            let arguments = message["params"]?["arguments"] ?? .object([:])
            do {
                let result = try await handler.callTool(name, arguments: arguments, client: handler.clientName)
                return Self.reply(to: message, result: result)
            } catch let failure as MCPError {
                let code = switch failure {
                case .methodNotFound: -32601
                case .invalidParams: -32602
                }
                return Self.reply(to: message, error: (code, failure.localizedDescription))
            } catch {
                return Self.reply(to: message, result: Self.errorContent(error.localizedDescription))
            }
        case "resources/list":
            let resources = await handler.resources(client: handler.clientName)
            return Self.reply(to: message, result: ["resources": .array(resources)])
        case "resources/read":
            guard let uri = message["params"]?["uri"]?.string else {
                return Self.reply(to: message, error: (-32602, "resources/read without a uri"))
            }
            do {
                let text = try await handler.readResource(uri, client: handler.clientName)
                return Self.reply(to: message, result: [
                    "contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(text)]],
                ])
            } catch {
                return Self.reply(to: message, error: (-32602, error.localizedDescription))
            }
        default:
            return Self.reply(to: message, error: (-32601, "no such method \(method)"))
        }
    }

    // The transport-level entry: JSON-RPC bytes in, reply bytes out; a
    // notification (or undecodable line) answers empty.
    public func handle(data: Data) async -> Data {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let reply = await handle(message) else { return Data() }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    // One tool result: structured content plus its JSON as the text block
    // clients without structured support read.
    public static func content(_ result: JSONValue) -> JSONValue {
        let text = (try? String(decoding: JSONEncoder().encode(result), as: UTF8.self)) ?? "null"
        return [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": result,
            "isError": .bool(false),
        ]
    }

    public static func errorContent(_ message: String) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(message)]],
            "isError": .bool(true),
        ]
    }

    public static func reply(to message: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": message["id"] ?? .null, "result": result]
    }

    public static func reply(to message: JSONValue, error: (Int, String)) -> JSONValue {
        [
            "jsonrpc": "2.0",
            "id": message["id"] ?? .null,
            "error": ["code": .number(Double(error.0)), "message": .string(error.1)],
        ]
    }
}
