import Foundation
import RetroArchKit

public enum MCPChannelError: LocalizedError {
    case unreachable(String)
    // The request went out, then the connection died: replaying it could run the tool twice, so callers must not retry this one.
    case broken(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail), .broken(let detail): detail
        }
    }
}

// A request/reply pipe to the app's MCP handler; whole JSON-RPC lines, one at a time.
public protocol MCPRequestChannel: Sendable {
    func send(_ request: Data) async throws -> Data
}

// Answers the channel's caller when the app cannot be reached: a proper JSON-RPC error with the request's own id, so the client is not left waiting.
public enum MCPUnreachable {

    public static func reply(to request: Data, reason: String) -> Data {
        let message = (try? JSONDecoder().decode(JSONValue.self, from: request)) ?? .object([:])
        let reply = MCPServer.reply(to: message, error: (-32000, reason))
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    public static func isNotification(_ request: Data) -> Bool {
        (try? JSONDecoder().decode(JSONValue.self, from: request))?["id"] == nil
    }
}
