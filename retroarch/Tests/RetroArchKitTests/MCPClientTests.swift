import Foundation
import Synchronization
import Testing

@testable import RetroArchKit

// The client against a server played by the test itself
@Suite("MCP client")
struct MCPClientTests {

    final class Wire: Sendable {
        let sent = Mutex<[JSONValue]>([])
        func send(_ data: Data) throws {
            let message = try JSONDecoder().decode(JSONValue.self, from: data)
            sent.withLock { $0.append(message) }
        }
        var messages: [JSONValue] { sent.withLock { $0 } }
    }

    private func answer(_ client: MCPClient, id: Int, _ result: JSONValue) async throws {
        let line = try MCPClient.encode(["jsonrpc": "2.0", "id": .number(Double(id)), "result": result])
        await client.receive(line.dropLast())
    }

    private func waitForSent(_ wire: Wire, count: Int) async {
        for _ in 0..<200 where wire.messages.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func sendsOneLinePerMessage() throws {
        let line = try MCPClient.encode(["text": "two\nlines"])
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
    }

    @Test func answersAreMatchedById() async throws {
        let wire = Wire()
        let client = MCPClient(send: wire.send)
        async let first = client.call("GET_STATUS")
        async let second = client.call("GET_OPTION")
        await waitForSent(wire, count: 2)
        let ids = wire.messages.compactMap { $0["id"]?.int }
        let names = wire.messages.compactMap { $0["params"]?["name"]?.string }
        #expect(ids.count == 2)
        // answered in the other order
        for (id, name) in zip(ids, names).reversed() {
            try await answer(client, id: id, ["content": [["type": "text", "text": .string("\(name) reply")]]])
        }
        #expect(try await first.text == "GET_STATUS reply")
        #expect(try await second.text == "GET_OPTION reply")
    }

    @Test func protocolErrorsAreThrown() async throws {
        let wire = Wire()
        let client = MCPClient(send: wire.send)
        let call = Task { try await client.call("NOPE") }
        await waitForSent(wire, count: 1)
        let id = try #require(wire.messages.first?["id"]?.int)
        let line = try MCPClient.encode([
            "jsonrpc": "2.0", "id": .number(Double(id)), "error": ["code": -32602, "message": "Unknown tool."],
        ])
        await client.receive(line.dropLast())
        await #expect(throws: MCPClientError.rpc(code: -32602, message: "Unknown tool.")) { try await call.value }
    }

    @Test func toolFailuresAreMarked() async throws {
        let wire = Wire()
        let client = MCPClient(send: wire.send)
        async let call = client.call("LOAD_CONTENT")
        await waitForSent(wire, count: 1)
        let id = try #require(wire.messages.first?["id"]?.int)
        try await answer(client, id: id, [
            "content": [["type": "text", "text": "LOAD_CONTENT ERROR no core at /x"]], "isError": true,
        ])
        let result = try await call
        #expect(result.isError)
        #expect(result.text == "LOAD_CONTENT ERROR no core at /x")
    }

    @Test func imagesAndRowsAreKept() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = ToolResult([
            "content": [
                ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"],
                ["type": "text", "text": "/shots/a.png"],
            ],
            "structuredContent": ["rows": [["name": "snes9x"]]],
        ])
        #expect(result.images == [png])
        #expect(result.text == "/shots/a.png")
        #expect(result.structured?["rows"]?.array?.count == 1)
    }

    @Test func unansweredRequestsTimeOut() async throws {
        let client = MCPClient(send: { _ in })
        await #expect(throws: MCPClientError.timedOut("tools/call")) {
            try await client.call("GET_STATUS", timeout: .milliseconds(50))
        }
    }

    @Test func closingFailsWhatWaits() async throws {
        let wire = Wire()
        let client = MCPClient(send: wire.send)
        let call = Task { try await client.call("GET_STATUS") }
        await waitForSent(wire, count: 1)
        await client.close()
        await #expect(throws: MCPClientError.closed) { try await call.value }
        await #expect(throws: MCPClientError.closed) { try await client.call("GET_STATUS") }
    }

    @Test func logNotificationsAreKept() async throws {
        let client = MCPClient(send: { _ in })
        let line = try MCPClient.encode([
            "jsonrpc": "2.0", "method": "notifications/message",
            "params": ["level": "info", "data": "[Core] Loading dynamic libretro core"],
        ])
        await client.receive(line.dropLast())
        #expect(await client.recentLog == ["[Core] Loading dynamic libretro core"])
    }

    @Test func handshakeNamesAVersionRetroArchAnswers() async throws {
        let wire = Wire()
        let client = MCPClient(send: wire.send)
        async let hello = client.initialize(client: "Cartouche", version: "1")
        await waitForSent(wire, count: 1)
        let request = try #require(wire.messages.first)
        #expect(request["method"]?.string == "initialize")
        // one of the versions network/mcp_server.c lists at the pinned commit
        #expect(["2025-11-25", "2025-06-18", "2025-03-26"].contains(request["params"]?["protocolVersion"]?.string ?? ""))
        try await answer(client, id: request["id"]!.int!, ["protocolVersion": "2025-06-18"])
        _ = try await hello
        await waitForSent(wire, count: 2)
        #expect(wire.messages.last?["method"]?.string == "notifications/initialized")
    }
}
