import Foundation
import Testing

@testable import RetroArchKit

// The tools Cartouche calls, against tools/list as the pinned commit answers
// it. The fixture was captured from that commit; the live test below reads it
// again from a real build, so a submodule bump that changes a tool fails here.
@Suite("MCP tool contract")
struct ToolContractTests {

    @Test func pinnedCommitOffersEveryToolCartoucheCalls() throws {
        let map = ToolMap(try Fixtures.pinnedTools())
        #expect(map.missing.isEmpty, "missing: \(map.missing.map(\.tool))")
        #expect(map.available == Set(ToolMap.Need.allCases))
    }

    @Test func pinnedSchemasTakeWhatCartoucheSends() throws {
        let tools = Dictionary(uniqueKeysWithValues: try Fixtures.pinnedTools().map { ($0.name, $0) })
        let load = try #require(tools["LOAD_CONTENT"])
        #expect(load.required == ["content"])
        #expect(load.parameters["core"]?["type"]?.string == "string")
        let state = try #require(tools["STATE"])
        #expect(state.required == ["action", "slot"])
        #expect(state.parameters["slot"]?["type"]?.string == "integer")
        #expect(state.parameters["action"]?["enum"] == ["save", "load"])
        #expect(tools["GET_STATUS"]?.readOnly == true)
        #expect(tools["QUIT"]?.destructive == true)
    }

    @Test func aRenamedToolLeavesOnlyItsNeedUnavailable() throws {
        let renamed = try Fixtures.pinnedTools().map { tool -> MCPTool in
            var tool = tool
            if tool.name == "STATE" { tool.name = "SAVE_STATE_SLOT" }
            return tool
        }
        let map = ToolMap(renamed)
        #expect(map.missing == [.state])
        #expect(throws: RetroArchSessionError.toolUnavailable("STATE")) { try map.tool(for: .state) }
        #expect(try map.tool(for: .loadContent) == "LOAD_CONTENT")
    }

    @Test func aParameterLosingAValueMakesTheToolUnavailable() throws {
        let narrowed = try Fixtures.pinnedTools().map { tool -> MCPTool in
            guard tool.name == "STATE" else { return tool }
            var tool = tool
            tool.inputSchema = [
                "type": "object",
                "properties": ["action": ["type": "string", "enum": ["save"]], "slot": ["type": "integer"]],
            ]
            return tool
        }
        #expect(ToolMap(narrowed).missing == [.state])
    }

    @Test(arguments: [
        ("GET_STATUS CONTENTLESS", GameStatus(state: .contentless)),
        ("GET_STATUS PLAYING super_nes,Test Cart.sfc\n", GameStatus(state: .playing, system: "super_nes", content: "Test Cart.sfc")),
        ("GET_STATUS PAUSED playstation,Disc 1, the beginning.cue", GameStatus(state: .paused, system: "playstation", content: "Disc 1, the beginning.cue")),
    ])
    func statusRepliesAreRead(reply: String, expected: GameStatus) {
        #expect(GameStatus(reply: reply) == expected)
    }

    @Test func otherRepliesAreNotStatus() {
        #expect(GameStatus(reply: "GET_STATUS ERROR") == nil)
        #expect(GameStatus(reply: "Done.") == nil)
    }

    @Test(.enabled(if: Rig.hasRetroArch, "set CARTOUCHE_RETROARCH to a build of the pinned commit"))
    func liveToolsListMatchesThePinnedContract() async throws {
        let work = try scratchFolder("contract")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let session = RetroArchSession(launch: Rig.launch(AppendConfig(paths: paths), in: work))
        try await session.start()
        let live = await session.tools
        _ = await session.stop()

        #expect(live.missing.isEmpty)
        #expect(await session.serverVersion == "1.22.2")
        let pinned = try Fixtures.pinnedTools()
        #expect(live.tools.keys.sorted() == pinned.map(\.name).sorted())
        for tool in pinned {
            #expect(live.tools[tool.name]?.inputSchema == tool.inputSchema, "\(tool.name) changed its schema")
        }
    }
}
