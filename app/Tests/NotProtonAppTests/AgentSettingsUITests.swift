import Foundation
import RetroArchKit
import SwiftUI
import Testing

@testable import NotProtonApp

// Settings > Agents and the approval sheet on a fixture service. The model
// stays off so no listener, notification center or network is touched.
@MainActor
private func agentScene(
    _ level: AgentLevel = .standard
) throws -> (model: AgentControlModel, service: AgentService, backend: AgentFixture, scratch: ScratchDefaults) {
    let scratch = ScratchDefaults()
    let root = try scratchDirectory("agents")
    let backend = AgentFixture(home: root)
    let service = AgentService(backend: backend, level: level, providers: [AgentControls()], home: root)
    let model = AgentControlModel(service: service, defaults: scratch.defaults)
    service.notify = { _ in }
    return (model, service, backend, scratch)
}

private func installerGame() -> Game {
    Game(id: "installer:hades", source: .installer, name: "Hades", installed: true)
}

@Suite("Settings > Agents", .serialized)
@MainActor
struct AgentSettingsUITests {

    @Test("The pane shows the toggle, the level, the connect rows and an empty log")
    func pane() async throws {
        let (model, _, _, _) = try agentScene()
        let host = UIHost(AgentsSettingsView(model: model), size: CGSize(width: 640, height: 560))
        defer { host.close() }
        #expect(try await host.wait(for: "Let agents control Cartouche"))
        let texts = try host.texts()
        for wanted in ["Access", "Claude Code", "claude mcp add cartouche -- '",
                       "Other clients over HTTP", "Recent Agent Actions", "No agent actions yet"] {
            #expect(texts.contains { $0.contains(wanted) }, "\(wanted) in \(texts)")
        }
        _ = try host.texts(named: "agents-settings")
    }

    @Test("Turning HTTP on shows the loopback URL, the token and a copyable client configuration")
    func http() async throws {
        let (model, _, _, _) = try agentScene()
        let host = UIHost(AgentsSettingsView(model: model), size: CGSize(width: 640, height: 560))
        defer { host.close() }
        #expect(model.clientConfiguration.contains("/Contents/Helpers/cartouche-mcp\""))

        model.httpEnabled = true
        #expect(try await host.wait(for: "Bearer token"))
        let texts = try host.texts()
        #expect(texts.contains { $0.contains("127.0.0.1:\(model.httpPort)/mcp") }, "\(texts)")
        // The 64-hex-digit token is truncated in the middle; Copy gives the whole of it
        #expect(texts.contains { $0.contains(model.token.prefix(16)) }, "\(texts)")
        #expect(texts.contains { $0.contains("Client configuration") }, "\(texts)")
        #expect(model.clientConfiguration.contains("\"url\": \"http://127.0.0.1:\(model.httpPort)/mcp\""))
        #expect(model.clientConfiguration.contains("Bearer \(model.token)"))
        _ = try host.texts(named: "agents-settings-http")
    }

    @Test("The level choice reaches the service and survives in defaults")
    func level() async throws {
        let (model, service, _, scratch) = try agentScene()
        #expect(service.level == .standard)
        model.level = .full
        #expect(service.level == .full)
        #expect(scratch.defaults.string(forKey: "agent.level") == "full")
        model.level = .readOnly
        #expect(service.level == .readOnly)
    }

    @Test("The log lists each action with its client and time; Undo restores the change")
    func log() async throws {
        let (model, service, backend, _) = try agentScene()
        let game = installerGame()
        backend.gameList = [game]
        _ = await service.call("set_favorite", ["game": .string(game.id), "on": .bool(true)],
                               client: "claude")

        let host = UIHost(AgentsSettingsView(model: model), size: CGSize(width: 640, height: 560))
        defer { host.close() }
        #expect(try await host.wait(for: "set_favorite"))
        let texts = try host.texts()
        #expect(texts.contains { $0.contains("claude") }, "\(texts)")
        #expect(texts.contains { $0.contains("Undo") }, "\(texts)")

        let action = try #require(model.actions.last { $0.canUndo })
        await model.undo(action)
        #expect(backend.favorites.isEmpty)
        #expect(model.actions.last { $0.undone } != nil)
        _ = try host.texts(named: "agents-settings-undo")
    }

    @Test("A pending approval shows in the pane with its text and answers there")
    func pendingRow() async throws {
        let (model, service, _, _) = try agentScene()
        let (stream, yield) = AsyncStream<AgentApproval>.makeStream()
        service.notify = { yield.yield($0) }
        var nextApproval = stream.makeAsyncIterator()
        let asked = Task {
            await service.ask(client: "claude", tool: "install_from_installer",
                              text: "install Hades (4.2 GB)")
        }
        _ = await nextApproval.next()
        let host = UIHost(AgentsSettingsView(model: model), size: CGSize(width: 640, height: 560))
        defer { host.close() }
        #expect(try await host.wait(for: "Waiting for You"))
        #expect(try host.texts().contains { $0.contains("wants to install Hades") })

        let approval = try #require(model.pending.first)
        model.answer(approval, allow: false)
        #expect(await asked.value == false)
        #expect(model.pending.isEmpty)
    }
}

@Suite("Agent approval sheet")
@MainActor
struct AgentApprovalUITests {

    @Test("The sheet asks Allow or Deny; Deny answers the suspended call with an error")
    func deny() async throws {
        let (model, service, backend, _) = try agentScene(.full)
        backend.gameList = [installerGame()]
        let (stream, yield) = AsyncStream<AgentApproval>.makeStream()
        service.notify = { yield.yield($0) }
        var nextApproval = stream.makeAsyncIterator()
        let call = Task {
            await service.call("run_winetricks",
                ["game": .string("installer:hades"), "verbs": .array([.string("vcrun2022")])],
                client: "claude")
        }
        let approval = try #require(await nextApproval.next())
        let host = UIHost(AgentApprovalSheet(approval: approval, model: model),
                          size: CGSize(width: 380, height: 200))
        defer { host.close() }
        let texts = try await {
            _ = try await host.wait(for: "Cartouche agent request")
            return try host.texts()
        }()
        #expect(texts.contains { $0.contains("wants to run Winetricks") }, "\(texts)")
        #expect(texts.contains("Allow") && texts.contains("Deny"))

        model.answer(approval, allow: false)
        let reply = await call.value
        #expect(reply["isError"] == .bool(true))
        #expect(service.actions.contains { $0.outcome == .denied })
        #expect(backend.calls.isEmpty)
    }

    @Test("Allow runs the call the sheet was shown for")
    func allow() async throws {
        let (model, service, backend, _) = try agentScene(.full)
        backend.gameList = [installerGame()]
        let (stream, yield) = AsyncStream<AgentApproval>.makeStream()
        service.notify = { yield.yield($0) }
        var nextApproval = stream.makeAsyncIterator()
        let call = Task {
            await service.call("run_winetricks",
                ["game": .string("installer:hades"), "verbs": .array([.string("vcrun2022")])],
                client: "claude")
        }
        let approval = try #require(await nextApproval.next())
        model.answer(approval, allow: true)
        let reply = await call.value
        #expect(reply["isError"] == .bool(false))
        #expect(backend.calls.contains("winetricks:vcrun2022"))
        #expect(model.pending.isEmpty)
    }
}
