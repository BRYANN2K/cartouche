import Darwin
import Foundation

// RetroArch's UDP command interface on 127.0.0.1, the fallback for builds
// without the MCP server: QUIT to stop, GET_STATUS to ask what runs
enum NetworkCommands {

    // Sends one command; with a wait, returns the first reply that comes
    static func send(_ command: String, port: UInt16, wait: Duration? = nil) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bytes = Array(command.utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == bytes.count, let wait else { return nil }

        let (seconds, attoseconds) = wait.components
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }
}
