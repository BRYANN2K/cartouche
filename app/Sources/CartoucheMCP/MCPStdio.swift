import Foundation
import RetroArchKit

// The helper's half of the pipe: one JSON-RPC message per stdin line, replies
// on stdout. Everything else (logging, diagnostics) stays off stdout, which is
// the MCP channel itself.
public enum MCPStdio {

    // Serves stdin until EOF. Each line goes to the app through the channel;
    // a line that is not JSON gets a parse error back when it carries an id.
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
            // stdin died; the helper exits quietly.
        }
    }

    static func write(_ data: Data, to output: FileHandle) {
        var line = data
        if line.last != 0x0A { line.append(0x0A) }
        output.write(line)
    }
}
