import CartoucheMCP
import Foundation
import InstallerKit
import Observation
import RetroArchKit

// One entry in Settings > Agents' action log: who called what, when, how it
// ended, and whether the user already undid it.
struct AgentAction: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let client: String
    let tool: String
    let detail: String
    var outcome: Outcome
    var undone = false
    var canUndo: Bool { undo != nil }

    enum Outcome: Equatable {
        case ok, refused(String), denied, error(String), undone
    }

    var undo: (() async throws -> Void)? = nil

    static func == (a: AgentAction, b: AgentAction) -> Bool {
        a.id == b.id && a.time == b.time && a.client == b.client && a.tool == b.tool
            && a.detail == b.detail && a.outcome == b.outcome && a.undone == b.undone
    }
}

// The approval the app shows when a risky tool is called: the tool suspends
// until Allow, Deny or the timeout, whichever comes first.
struct AgentApproval: Identifiable {
    let id = UUID()
    let client: String
    let text: String
    let tool: String
    let asked: Date
    let answer: CheckedContinuation<Bool, Never>
}

@MainActor
@Observable
final class AgentService {

    let backend: AgentBackend
    private(set) var tools: [String: AgentTool]
    var level: AgentLevel
    // How long an approval waits for the user before it answers Denied.
    var approvalTimeout: Duration = .seconds(300)
    // Posts the "Claude wants to…" notification; injected for tests.
    var notify: @MainActor (AgentApproval) -> Void = { _ in }

    private(set) var actions: [AgentAction] = []
    private(set) var pending: [AgentApproval] = []
    // Who the MCP client said it was at initialize; the action log records it.
    var clientName = "agent"
    var home: URL

    init(backend: AgentBackend, level: AgentLevel = .readOnly,
         providers: [AgentToolProvider] = [], home: URL = SupportPaths.home) {
        self.backend = backend
        self.level = level
        self.home = home
        tools = Dictionary(AgentTools.all(providers: providers).map { ($0.name, $0) },
                           uniquingKeysWith: { a, _ in a })
    }

    // Registers a tool after init: AgentControls uses this for P15.
    func register(_ new: [AgentTool]) {
        for tool in new { tools[tool.name] = tool }
    }

    // MARK: - tools/list

    var toolList: [[String: JSONValue]] {
        tools.values.sorted { $0.name < $1.name }.map {
            ["name": .string($0.name), "description": .string($0.detail), "inputSchema": $0.schema]
        }
    }

    // MARK: - tools/call: level, hardcore, approval, run, scan, log

    func call(_ name: String, _ args: JSONValue, client: String) async -> JSONValue {
        guard let tool = tools[name] else {
            return MCPServer.errorContent("no tool named \(name)")
        }
        guard tool.level <= level else {
            return refuse(tool, "needs \(tool.level.rawValue) access; the level is \(level.rawValue)",
                          client: client)
        }
        if tool.sendsInput, let playing = backend.consolePlaying(),
           backend.consoleGame(playing.gameID)?.setup.hardcore == true {
            return refuse(tool, "Hardcore achievements are on; \(name) is refused while it is",
                          client: client)
        }
        if tool.approval {
            let text = tool.approvalText?(backend, args) ?? name
            guard await ask(client: client, tool: name, text: text) else {
                return deny(tool, client: client)
            }
        }
        let undo = snapshotUndo(tool: name, args: args)
        do {
            let raw = try await tool.run(backend, args)
            let scanned = AgentScan.scrub(raw, under: backend.roots.allowed, home: home)
            record(client: client, tool: name, detail: describe(args), outcome: .ok, undo: undo)
            return MCPServer.content(scanned)
        } catch {
            record(client: client, tool: name, detail: describe(args), outcome: .error(error.localizedDescription))
            return MCPServer.errorContent(error.localizedDescription)
        }
    }

    private func refuse(_ tool: AgentTool, _ why: String, client: String) -> JSONValue {
        record(client: client, tool: tool.name, detail: "", outcome: .refused(why))
        return MCPServer.errorContent("refused: \(tool.name) \(why)")
    }

    private func deny(_ tool: AgentTool, client: String) -> JSONValue {
        record(client: client, tool: tool.name, detail: "", outcome: .denied)
        return MCPServer.errorContent("the user denied \(tool.name)")
    }

    // MARK: - Approvals

    // Suspends until the user answers in the app or the timeout denies.
    func ask(client: String, tool: String, text: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let approval = AgentApproval(client: client, text: text, tool: tool,
                                         asked: Date(), answer: continuation)
            pending.append(approval)
            notify(approval)
            Task { [weak self, id = approval.id] in
                try? await Task.sleep(for: self?.approvalTimeout ?? .seconds(300))
                self?.answer(id, allow: false)
            }
        }
    }

    func answer(_ id: UUID, allow: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let approval = pending.remove(at: index)
        approval.answer.resume(returning: allow)
    }

    // MARK: - Action log and undo

    private func record(client: String, tool: String, detail: String, outcome: AgentAction.Outcome,
                        undo: (() async throws -> Void)? = nil) {
        var entry = AgentAction(time: Date(), client: client, tool: tool, detail: detail, outcome: outcome)
        entry.undo = undo
        actions.append(entry)
        if actions.count > 500 { actions.removeFirst(actions.count - 500) }
        appendToLog(entry)
    }

    func undo(_ id: UUID) async throws {
        guard let index = actions.firstIndex(where: { $0.id == id }),
              let undo = actions[index].undo else { return }
        try await undo()
        actions[index].undone = true
        record(client: actions[index].client, tool: actions[index].tool,
               detail: "undo \(actions[index].detail)", outcome: .undone, undo: nil)
    }

    // The log file keeps the record across restarts; the undo closures cannot.
    private func appendToLog(_ entry: AgentAction) {
        let folder = backend.roots.support.appending(path: "agents")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outcome: String
        switch entry.outcome {
        case .ok: outcome = "ok"
        case .refused(let why): outcome = "refused: \(why)"
        case .denied: outcome = "denied"
        case .error(let why): outcome = "error: \(why)"
        case .undone: outcome = "undone"
        }
        let line = "{\"time\":\"\(AgentTools.stamp.string(from: entry.time))\","
            + "\"client\":\(Self.quote(entry.client)),\"tool\":\(Self.quote(entry.tool)),"
            + "\"detail\":\(Self.quote(entry.detail)),\"outcome\":\(Self.quote(outcome))}\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: folder.appending(path: "actions.jsonl")) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else if let data = line.data(using: .utf8) {
            try? data.write(to: folder.appending(path: "actions.jsonl"))
        }
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func describe(_ args: JSONValue) -> String {
        guard let object = args.object, !object.isEmpty else { return "" }
        return object.keys.sorted().compactMap { key in
            args[key]?.string ?? args[key]?.int.map(String.init) ?? args[key]?.bool.map { "\($0)" }
        }.joined(separator: " ")
    }

    // MARK: - resources/read

    // The same scrub a tool result gets: a resource may quote a path.
    func readResource(_ uri: String) throws -> String {
        let text: JSONValue
        switch uri {
        case "cartouche://status":
            text = [
                "level": .string(level.rawValue),
                "client": .string(clientName),
                "tools": .number(Double(tools.count)),
                "pending": .number(Double(pending.count)),
            ]
        case "cartouche://pending":
            text = .array(pending.map {
                ["tool": .string($0.tool), "client": .string($0.client), "text": .string($0.text)]
            })
        case "cartouche://actions":
            text = .array(actions.suffix(100).map {
                ["time": .string(AgentTools.stamp.string(from: $0.time)),
                 "client": .string($0.client), "tool": .string($0.tool),
                 "detail": .string($0.detail), "outcome": .string("\($0.outcome)"),
                 "undone": .bool($0.undone)]
            })
        default:
            throw MCPError.methodNotFound("unknown resource \(uri)")
        }
        let scrubbed = AgentScan.scrub(text, under: backend.roots.allowed, home: home)
        return String(decoding: (try? JSONEncoder().encode(scrubbed)) ?? Data(), as: UTF8.self)
    }

    // MARK: - Undo snapshots

    // Which tools restore cleanly: config changes, favorites, hidden, the
    // default runner, console setup. Installs and deletions cannot be undone.
    private func snapshotUndo(tool: String, args: JSONValue) -> (() async throws -> Void)? {
        let backend = backend
        let gameID = (try? AgentTools.find(backend, args))?.id
        switch tool {
        case "set_game_config", "set_version", "apply_recommended_setup", "launch_game":
            guard let gameID, backend.game(gameID) != nil else { return nil }
            let before = backend.setupChoice(for: gameID)
            return { backend.setSetup(before, for: gameID) }
        case "set_favorite":
            guard let gameID else { return nil }
            let was = backend.isFavorite(gameID)
            return { backend.setFavorite(gameID, on: was) }
        case "hide_game":
            guard let gameID else { return nil }
            let was = backend.isHidden(gameID)
            return { backend.hide(gameID, on: was) }
        case "set_default_runner":
            let was = backend.defaultRunner()
            return { if let was { backend.setDefaultRunner(was) } }
        case "set_console_setup":
            guard let id = args["game"]?.string,
                  let before = backend.consoleGame(id)?.setup else { return nil }
            return { await backend.setConsoleSetup(id) { $0 = before } }
        case "set_controls", "set_keyboard_mouse", "set_controller_for_keyboard_game":
            guard let gameID, backend.game(gameID) != nil else { return nil }
            let before = backend.gameControls(gameID)
            return { try await backend.setGameControls(before, for: gameID) }
        default:
            return nil
        }
    }
}
