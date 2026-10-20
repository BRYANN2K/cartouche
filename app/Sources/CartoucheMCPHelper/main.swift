import CartoucheMCP
import Foundation

//// cartouche-mcp is the stdio face of Cartouche's MCP server: it carries each JSON-RPC line to the app over the local
//// socket at ~/Library/Application Support/Cartouche/agent/mcp.sock, so every check and approval stays in the app itself.
////
//// claude mcp add cartouche -- cartouche-mcp
////
//// When Cartouche is not running the first send fails; the helper asks LaunchServices to open it and retries.

enum HelperError: LocalizedError {
    case appNotAnswering

    var errorDescription: String? {
        switch self {
        case .appNotAnswering: "Cartouche is not running and could not be opened"
        }
    }
}

// CARTOUCHE_APP points `swift run` debugging at a built bundle to open; normally the app is opened by its bundle identifier.
func appOverride() -> URL? {
    guard let given = ProcessInfo.processInfo.environment["CARTOUCHE_APP"], !given.isEmpty else {
        return nil
    }
    return URL(filePath: given)
}

struct LaunchingChannel: MCPRequestChannel {

    let client: MCPSocketClient
    let bundle: URL?

    func send(_ request: Data) async throws -> Data {
        do {
            return try await client.send(request)
        } catch {
            guard Self.unreachable(error) else { throw error }
        }
        try launchApp()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            do {
                return try await client.send(request)
            } catch {
                guard Self.unreachable(error) else { throw error }
            }
        }
        throw HelperError.appNotAnswering
    }

    // Only "the app is not there" may re-send: once connect() succeeded the request went out and replaying it could run the tool twice.
    private static func unreachable(_ error: Error) -> Bool {
        guard let error = error as? MCPChannelError else { return false }
        if case .unreachable = error { return true }
        return false
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
