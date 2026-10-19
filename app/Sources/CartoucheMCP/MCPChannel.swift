import Foundation
import RetroArchKit

public enum MCPChannelError: LocalizedError {
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): detail
        }
    }
}

// A request/reply pipe to the app's MCP handler: the local socket for the
// bundled helper, a direct object in tests. Carries whole JSON-RPC lines, one
// at a time.
public protocol MCPRequestChannel: Sendable {
    func send(_ request: Data) async throws -> Data
}

// Answers the channel's caller when the app cannot be reached: a proper
// JSON-RPC error with the request's own id, so the client is not left waiting.
public enum MCPUnreachable {

    public static func reply(to request: Data, reason: String) -> Data {
        let id = (try? JSONDecoder().decode(JSONValue.self, from: request))?["id"] ?? .null
        let reply: JSONValue = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": .number(-32000), "message": .string(reason)],
        ]
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    // The id of a notification is absent, so a notification gets no error reply.
    public static func isNotification(_ request: Data) -> Bool {
        (try? JSONDecoder().decode(JSONValue.self, from: request))?["id"] == nil
    }
}
