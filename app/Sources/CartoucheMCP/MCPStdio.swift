import Foundation
import RetroArchKit

// The helper's half of the pipe: one JSON-RPC message per stdin line, replies on stdout. Everything else (logging, diagnostics) stays off stdout, which is the MCP channel itself.
public enum MCPStdio {

    public static func serve(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        channel: any MCPRequestChannel
    ) async {
        // Split on LF only: AsyncLineSequence also breaks on U+2028/U+2029, which JSON strings may carry raw.
        var line = Data()
        do {
            for try await byte in input.bytes {
                if byte == 0x0A {
                    await handle(line, channel: channel, output: output)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        } catch {
        }
        await handle(line, channel: channel, output: output)
    }

    private static func handle(_ line: Data, channel: any MCPRequestChannel, output: FileHandle) async {
        let data = line.last == 0x0D ? line.dropLast() : line
        guard !data.isEmpty else { return }
        let reply: Data
        do {
            reply = try await channel.send(Data(data))
        } catch {
            if MCPUnreachable.isNotification(Data(data)) { return }
            reply = MCPUnreachable.reply(to: Data(data), reason: error.localizedDescription)
        }
        guard !reply.isEmpty else { return }
        write(reply, to: output)
    }

    static func write(_ data: Data, to output: FileHandle) {
        var line = data
        if line.last != 0x0A { line.append(0x0A) }
        output.write(line)
    }
}
