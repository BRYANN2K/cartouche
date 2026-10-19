import Foundation
import RetroArchKit
import Testing

@testable import CartoucheMCP
@testable import NotProtonApp

// The agent's CLI sandbox denies AF_UNIX bind even in writable folders; where
// a probe bind fails the tests that need a bound socket skip instead of
// failing. socketpair() is not denied, so the peer checks, the read/serve path
// and the refusal all run for real over a pair of connected fds.
private let socketsPermitted: Bool = {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let path = URL.temporaryDirectory
        .appending(path: "probe\(getpid()).s").path(percentEncoded: false)
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    unlink(path)
    return bound == 0
}()

private func socketPair() throws -> (server: Int32, client: Int32) {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        throw MCPChannelError.unreachable("socketpair failed")
    }
    return (pair[0], pair[1])
}

private func posixWrite(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let sent = write(fd, base + offset, bytes.count - offset)
            guard sent > 0 else { throw MCPChannelError.unreachable("write failed") }
            offset += sent
        }
    }
}

// Reads to a newline, or to the end when the peer closed the connection.
private func posixReadLine(_ fd: Int32) throws -> Data {
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let got = read(fd, &chunk, chunk.count)
        guard got >= 0 else { throw MCPChannelError.unreachable("read failed") }
        if got == 0 { break }
        if let newline = chunk[0..<got].firstIndex(of: 0x0A) {
            reply.append(contentsOf: chunk[0..<newline])
            break
        }
        reply.append(contentsOf: chunk[0..<got])
    }
    return reply
}

// The local socket transport: a real socket in a scratch folder, not the
// user's data folder. sun_path is 104 bytes, so the scratch names stay short.
private func scratchSocket() throws -> URL {
    let dir = URL.temporaryDirectory.appending(path: "ms\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appending(path: "s")
}

private func pipe(_ server: MCPServer) -> @Sendable (Data) async -> Data {
    { data in
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let reply = await server.handle(message) else { return Data() }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }
}

private struct PingHandler: MCPHandling {
    var serverVersion: String { "test/1" }
    var clientName: String { "test" }
    func initialize(client: String) async {}
    func tools(client: String) async -> [MCPToolInfo] { [] }
    func callTool(_ name: String, arguments: JSONValue, client: String) async throws -> JSONValue {
        MCPServer.content(["echo": .string(name)])
    }
}

// The peer check tests inject: this process's own executable as the kernel
// reports it, the same way the app admits the bundled helper's path.
private func ownExecutable() -> String {
    MCPSocketServer.executablePath(of: getpid()) ?? ""
}

@Suite("MCP socket transport")
struct MCPSocketTests {

    @Test("the default path is inside Cartouche's data folder, the same file the app binds")
    func defaultPath() {
        let path = MCPSocketPath.file.path(percentEncoded: false)
        #expect(path.hasSuffix(
            "/Library/Application Support/\(SupportPaths.supportDirName)/agent/mcp.sock"))
        #expect(path == SupportPaths.agentSocket.path(percentEncoded: false))
        #expect(MCPSocketServer.bundledHelper(in: URL(filePath: "/x/Cartouche.app"))
            .hasSuffix("/Contents/Helpers/cartouche-mcp"))
    }

    @Test("a request through a served connection gets the server's reply")
    func servedRoundTrip() async throws {
        let pair = try socketPair()
        defer { close(pair.client) }
        let server = MCPSocketServer(
            socket: URL(filePath: "/tmp/unused-s"), handler: pipe(MCPServer(handler: PingHandler()))
        ) { $0 == ownExecutable() }
        server.adopt(pair.server)
        defer { server.stop() }

        try posixWrite(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [0x0A]),
                       to: pair.client)
        let reply = try await Task.detached { try posixReadLine(pair.client) }.value
        let parsed = try JSONDecoder().decode(JSONValue.self, from: reply)
        #expect(parsed["id"] == .number(1))
        #expect(parsed["result"] != nil)
    }

    @Test("the peer check admits this user's own executable and refuses another path")
    func peerCheck() throws {
        let pair = try socketPair()
        defer { close(pair.server); close(pair.client) }
        let admitted = MCPSocketServer(
            socket: URL(filePath: "/tmp/unused-s"), handler: { _ in Data() }
        ) { $0 == ownExecutable() }
        #expect(admitted.admit(pair.server))
        let refused = MCPSocketServer(
            socket: URL(filePath: "/tmp/unused-s"), handler: { _ in Data() }
        ) { $0 == "/usr/bin/not-the-helper" }
        #expect(!refused.admit(pair.client))
    }

    @Test("a non-socket fd fails the peer check")
    func peerCheckNotASocket() throws {
        let fd = open("/dev/null", O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let server = MCPSocketServer(
            socket: URL(filePath: "/tmp/unused-s"), handler: { _ in Data() }) { _ in true }
        #expect(!server.admit(fd))
    }

    @Test("a peer whose executable is not the bundled helper is refused")
    func refusedPeer() async throws {
        let pair = try socketPair()
        defer { close(pair.client) }
        let seen = Box<String?>(nil)
        let server = MCPSocketServer(
            socket: URL(filePath: "/tmp/unused-s"), handler: { _ in Data() }
        ) { path in
            seen.value = path
            return false
        }
        server.adopt(pair.server)
        defer { server.stop() }

        try posixWrite(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [0x0A]),
                       to: pair.client)
        // The refused connection is closed: the read sees EOF, not a reply.
        let reply = try await Task.detached { try posixReadLine(pair.client) }.value
        #expect(reply.isEmpty)
        #expect(seen.value == ownExecutable())
    }

    @Test("a missing socket answers unreachable, not a hang")
    func missingSocket() async throws {
        let missing = URL.temporaryDirectory.appending(path: "gone\(getpid()).s")
        let client = MCPSocketClient(socket: missing)
        await #expect(throws: MCPChannelError.self) {
            try await client.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        }
    }

    @Test("a request over a real socket gets the server's reply",
          .enabled(if: socketsPermitted, "this sandbox denies Unix-socket binds"))
    func roundTrip() async throws {
        let socket = try scratchSocket()
        // A stale file at the socket's path is unlinked before bind.
        try "stale".write(to: socket, atomically: true, encoding: .utf8)
        let server = MCPSocketServer(
            socket: socket, handler: pipe(MCPServer(handler: PingHandler()))
        ) { $0 == ownExecutable() }
        try server.start()
        defer { server.stop() }

        let client = MCPSocketClient(socket: socket)
        let ping = try await client.send(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: ping)
        #expect(parsed["id"] == .number(1))
        #expect(parsed["result"] != nil)

        let tools = try await client.send(
            Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        let listed = try JSONDecoder().decode(JSONValue.self, from: tools)
        #expect(listed["id"] == .number(2))
        #expect(listed["result"]?["tools"]?.array != nil)
    }

    @Test("the folder is 0700 and the socket file 0600",
          .enabled(if: socketsPermitted, "this sandbox denies Unix-socket binds"))
    func permissions() throws {
        let socket = try scratchSocket()
        let server = MCPSocketServer(socket: socket, handler: { _ in Data() }) { _ in false }
        try server.start()
        defer { server.stop() }
        var info = stat()
        #expect(stat(socket.deletingLastPathComponent().path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(stat(socket.path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("stop unlinks the socket",
          .enabled(if: socketsPermitted, "this sandbox denies Unix-socket binds"))
    func removedOnStop() throws {
        let socket = try scratchSocket()
        let server = MCPSocketServer(socket: socket, handler: { _ in Data() }) { _ in false }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
    }
}
