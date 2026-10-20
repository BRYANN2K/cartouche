import Foundation
import RetroArchKit

// The helper's half of the pipe: one JSON-RPC message per stdin line, replies on stdout. Everything else (logging, diagnostics) stays off stdout, which is the MCP channel itself.
public enum MCPStdio {

    public static func serve(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        channel: any MCPRequestChannel
    ) async {
        do {
            for try await line in input.bytes.lines {
                guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                let reply: Data
                do {
                    reply = try await channel.send(data)
                } catch {
                    if MCPUnreachable.isNotification(data) { continue }
                    reply = MCPUnreachable.reply(to: data, reason: error.localizedDescription)
                }
                guard !reply.isEmpty else { continue }
                write(reply, to: output)
            }
        } catch {
        }
    }

    static func write(_ data: Data, to output: FileHandle) {
        var line = data
        if line.last != 0x0A { line.append(0x0A) }
        output.write(line)
    }
}
