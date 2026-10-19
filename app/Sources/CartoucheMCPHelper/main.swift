import CartoucheMCP
import Foundation

// cartouche-mcp is the stdio face of Cartouche's MCP server. Claude Desktop and
// Claude Code start it from Contents/Helpers inside the app bundle; it carries
// each JSON-RPC line to the app over the local socket at
// ~/Library/Application Support/Cartouche/agent/mcp.sock, so every check and
// approval stays in the app itself.
//
//   claude mcp add cartouche -- cartouche-mcp
//
// When Cartouche is not running the first send fails; the helper then asks
// LaunchServices to open the app and retries until the socket answers.

enum HelperError: LocalizedError {
    case appNotAnswering

    var errorDescription: String? {
        switch self {
        case .appNotAnswering: "Cartouche is not running and could not be opened"
        }
    }
}

// CARTOUCHE_APP points `swift run` debugging at a built bundle to open;
// normally the app is opened by its bundle identifier.
func appOverride() -> URL? {
    guard let given = ProcessInfo.processInfo.environment["CARTOUCHE_APP"], !given.isEmpty else {
        return nil
    }
    return URL(filePath: given)
}

// Starts Cartouche once, then waits for its socket to answer. Returns a
// channel that wraps send with that launch-and-retry.
struct LaunchingChannel: MCPRequestChannel {

    let client: MCPSocketClient
    let bundle: URL?

    func send(_ request: Data) async throws -> Data {
        do {
            return try await client.send(request)
        } catch {
            try launchApp()
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if let reply = try? await client.send(request) { return reply }
            }
            throw HelperError.appNotAnswering
        }
    }

    private func launchApp() throws {
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = bundle.map { ["-g", $0.path(percentEncoded: false)] }
            ?? ["-g", "-b", "dev.bryann2k.cartouche"]
        try open.run()
        open.waitUntilExit()
    }
}

let channel = LaunchingChannel(client: MCPSocketClient(), bundle: appOverride())
await MCPStdio.serve(channel: channel)
