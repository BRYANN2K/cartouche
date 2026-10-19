import CartoucheIdentity
import Foundation

// The local transport between the app and the bundled cartouche-mcp helper: a
// Unix socket inside Cartouche's data folder. One JSON-RPC message per line in
// each direction — the same frames MCPStdio carries. This replaces XPC: only
// a launchd job may vend a Mach service, and NSXPCConnection(serviceName:) is
// for XPC services bundled inside the connecting app.

// Where the socket lives: ~/Library/Application Support/<Cartouche>/agent/
// mcp.sock — the same root SupportPaths builds for the app; the helper cannot
// see that file, so the names come from the shared identity header.
public enum MCPSocketPath {
    public static var support: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support")
            .appending(path: CARTOUCHE_DIR_NAME)
    }

    public static var directory: URL { support.appending(path: CARTOUCHE_AGENT_DIR) }
    public static var file: URL { support.appending(path: CARTOUCHE_AGENT_SOCKET) }
}

public enum MCPSocketError: LocalizedError {
    case pathTooLong(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "the agent socket path is too long: \(path)"
        case .failed(let detail): detail
        }
    }
}

// sockaddr_un holds 104 bytes of path.
private func unixAddress(_ path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    guard bytes.count < 104 else { throw MCPSocketError.pathTooLong(path) }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    return address
}

private func unixSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw MCPSocketError.failed("socket: \(String(cString: strerror(errno)))")
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    return fd
}

// The app's half: binds the socket and answers each line through the same
// handler the HTTP transport uses. A peer is admitted only when it runs as
// this user (getpeereid) and its executable — read through LOCAL_PEERPID and
// proc_pidpath — passes the injected check: the bundled cartouche-mcp in the
// app, the test runner in tests.
public final class MCPSocketServer: @unchecked Sendable {

    private let handler: @Sendable (Data) async -> Data
    private let admitsExecutable: @Sendable (String) -> Bool
    private let socketURL: URL

    // Everything mutable runs on the serial queue; nothing else locks.
    private let queue = DispatchQueue(label: "cartouche.mcp.socket")
    private var listenSource: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]

    private static let byteLimit = 1 << 22

    public init(socket: URL = MCPSocketPath.file,
                handler: @escaping @Sendable (Data) async -> Data,
                admitsExecutable: @escaping @Sendable (String) -> Bool) {
        self.socketURL = socket
        self.handler = handler
        self.admitsExecutable = admitsExecutable
    }

    public func start() throws {
        try queue.sync {
            guard listenSource == nil else { return }
            let fd = try Self.listen(at: socketURL)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
            source.setCancelHandler { close(fd) }
            listenSource = source
            source.activate()
        }
    }

    // Closes the listener and every connection and unlinks the socket file, so
    // quitting the app leaves no stale path in the data folder.
    public func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for connection in Array(connections.values) { drop(connection) }
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    // MARK: Peer checks

    // The one executable the app's check admits: cartouche-mcp inside this .app.
    public static func bundledHelper(in bundle: URL = Bundle.main.bundleURL) -> String {
        normalized(bundle.appending(path: "Contents/Helpers/cartouche-mcp")
            .path(percentEncoded: false))
    }

    // The peer's executable, as the kernel reports it, normalized so a symlinked
    // bundle and proc_pidpath's answer compare equal.
    public static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN) does not import into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return normalized(String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
                                 as: UTF8.self))
    }

    public static func normalized(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
    }

    // The peer checks every accepted connection passes: same uid as the app,
    // and an executable the injected check admits. Internal so tests can call
    // it on socketpair fds — the CLI sandbox denies bind, not pairs.
    func admit(_ fd: Int32) -> Bool {
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid = pid_t(0)
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              let executable = Self.executablePath(of: pid)
        else { return false }
        return admitsExecutable(executable)
    }

    // Takes over a connected fd — accepted by the listener, or a socketpair
    // end in tests. The peer checks run first; a refused peer is closed.
    func adopt(_ fd: Int32) {
        queue.async { self.register(fd) }
    }

    // MARK: Connections

    // Queued tasks carry a connection only as an identity; its fields are
    // read and written on the serial queue alone.
    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        var inbound = Data()
        var outbox = Data()
        var readSource: DispatchSourceRead!
        var writeSource: DispatchSourceWrite?
        var writeArmed = false

        init(fd: Int32) { self.fd = fd }
    }

    private static func listen(at socketURL: URL) throws -> Int32 {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // The attribute above only lands on folders this call creates.
        chmod(dir.path(percentEncoded: false), 0o700)
        let path = socketURL.path(percentEncoded: false)
        unlink(path)
        let fd = try unixSocket()
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        do {
            var address = try unixAddress(path)
            guard withUnsafePointer(to: &address, { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }) == 0 else {
                throw MCPSocketError.failed("bind: \(String(cString: strerror(errno)))")
            }
            chmod(path, 0o600)
            guard Darwin.listen(fd, 16) == 0 else {
                throw MCPSocketError.failed("listen: \(String(cString: strerror(errno)))")
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            register(fd)
        }
    }

    // Runs on the queue.
    private func register(_ fd: Int32) {
        guard admit(fd) else { close(fd); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, self.connections[connection.id] === connection
            else { return }
            self.drain(connection)
        }
        connection.readSource = source
        connections[connection.id] = connection
        source.activate()
    }

    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        // The fd closes in a cancel handler so no queued event can meet a
        // reused fd number. A suspended source traps on cancel — and on
        // release — so a drained writer is resumed first.
        if let writer = connection.writeSource {
            if !connection.writeArmed { writer.resume() }
            writer.setCancelHandler { close(connection.fd) }
            writer.cancel()
        } else {
            connection.readSource?.setCancelHandler { close(connection.fd) }
        }
        connection.readSource?.cancel()
    }

    private func drain(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let got = read(connection.fd, &chunk, chunk.count)
            if got < 0 {
                if errno == EAGAIN { return }
                drop(connection)
                return
            }
            if got == 0 { drop(connection); return }
            connection.inbound.append(contentsOf: chunk[0..<got])
            if connection.inbound.count > Self.byteLimit { drop(connection); return }
            serveLines(connection)
        }
    }

    private func serveLines(_ connection: Connection) {
        while let newline = connection.inbound.firstIndex(of: 0x0A) {
            let request = Data(connection.inbound.prefix(upTo: newline))
            connection.inbound.removeSubrange(...newline)
            guard !request.isEmpty else { continue }
            Task { [handler, weak self, weak connection] in
                self?.enqueue(await handler(request), to: connection)
            }
        }
    }

    private func enqueue(_ reply: Data, to connection: Connection?) {
        queue.async { [weak self] in
            guard let self, let connection,
                  self.connections[connection.id] === connection else { return }
            // An empty reply is a notification: its work is done. Dropping the
            // connection gives a client still reading an EOF, not a hang.
            if reply.isEmpty { self.drop(connection); return }
            var line = reply
            if line.last != 0x0A { line.append(0x0A) }
            connection.outbox.append(line)
            if connection.outbox.count > Self.byteLimit { self.drop(connection); return }
            self.pump(connection)
        }
    }

    // Writes what fits; when the peer stops reading the rest waits for the
    // write source instead of stalling the queue.
    private func pump(_ connection: Connection) {
        while !connection.outbox.isEmpty {
            let sent = connection.outbox.withUnsafeBytes {
                write(connection.fd, $0.baseAddress, $0.count)
            }
            if sent > 0 {
                connection.outbox.removeFirst(sent)
            } else if sent < 0, errno == EAGAIN {
                armWriter(connection)
                return
            } else {
                drop(connection)
                return
            }
        }
        disarmWriter(connection)
    }

    private func armWriter(_ connection: Connection) {
        if connection.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection,
                      self.connections[connection.id] === connection else { return }
                self.pump(connection)
            }
            connection.writeSource = source
            source.activate()
            connection.writeArmed = true
        } else if !connection.writeArmed {
            connection.writeSource?.resume()
            connection.writeArmed = true
        }
    }

    private func disarmWriter(_ connection: Connection) {
        guard connection.writeArmed else { return }
        connection.writeSource?.suspend()
        connection.writeArmed = false
    }
}

// The helper's half: connects to the socket, sends one line, reads the one
// reply line back. Each send opens a fresh connection and a dead app fails
// fast on connect(). Once bytes went out the error is thrown, never retried:
// a replay could run a non-idempotent tool twice — retries only happen in
// LaunchingChannel and only when connect() failed.
public final class MCPSocketClient: MCPRequestChannel, @unchecked Sendable {

    private let socketURL: URL

    public init(socket: URL = MCPSocketPath.file) {
        self.socketURL = socket
    }

    public func send(_ request: Data) async throws -> Data {
        try await Task.detached { try self.call(request) }.value
    }

    private func call(_ request: Data) throws -> Data {
        let fd = try Self.connect(to: socketURL)
        defer { close(fd) }
        var line = request
        if line.last != 0x0A { line.append(0x0A) }
        try Self.writeAll(line, to: fd)
        // A notification has no id and earns no reply; reading would hang.
        guard !MCPUnreachable.isNotification(request) else { return Data() }
        return try Self.readReply(from: fd)
    }

    private static func connect(to socketURL: URL) throws -> Int32 {
        let fd: Int32
        do {
            fd = try unixSocket()
        } catch {
            throw MCPChannelError.unreachable("Cartouche is not running")
        }
        do {
            var address = try unixAddress(socketURL.path(percentEncoded: false))
            guard withUnsafePointer(to: &address, { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }) == 0 else {
                throw MCPChannelError.unreachable("Cartouche is not running")
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = write(fd, base + offset, bytes.count - offset)
                guard sent > 0 else {
                    throw MCPChannelError.broken("Cartouche did not answer")
                }
                offset += sent
            }
        }
    }

    private static func readReply(from fd: Int32) throws -> Data {
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let got = read(fd, &chunk, chunk.count)
            guard got >= 0 else {
                throw MCPChannelError.broken(String(cString: strerror(errno)))
            }
            if got == 0 { break }
            if let newline = chunk[0..<got].firstIndex(of: 0x0A) {
                reply.append(contentsOf: chunk[0..<newline])
                break
            }
            reply.append(contentsOf: chunk[0..<got])
            guard reply.count < 1 << 22 else {
                throw MCPChannelError.broken("Cartouche's reply is too large")
            }
        }
        guard !reply.isEmpty else {
            throw MCPChannelError.broken("Cartouche did not answer")
        }
        return reply
    }
}
