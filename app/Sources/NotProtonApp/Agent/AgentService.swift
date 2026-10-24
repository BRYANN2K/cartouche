import CartoucheMCP
import Foundation
import InstallerKit
import Observation
import RetroArchKit

struct AgentAction: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let client: String
    let tool: String
    let detail: String
    var outcome: Outcome
    var undone = false
    var canUndo: Bool { undo != nil && !undone }

    enum Outcome: Equatable {
        case ok, refused(String), denied, error(String)
    }

    var undo: (() async throws -> Void)? = nil

    static func == (a: AgentAction, b: AgentAction) -> Bool {
        a.id == b.id && a.time == b.time && a.client == b.client && a.tool == b.tool
            && a.detail == b.detail && a.outcome == b.outcome && a.undone == b.undone
    }
}

// The tool suspends until Allow, Deny or the timeout, whichever comes first.
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
    // An approval granted just before the model flips this off must not still run.
    var enabled = true
    var approvalTimeout: Duration = .seconds(300)
    var notify: @MainActor (AgentApproval) -> Void = { _ in }

    private(set) var actions: [AgentAction] = []
    private(set) var pending: [AgentApproval] = []
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    var home: URL

    init(backend: AgentBackend, level: AgentLevel = .readOnly,
         providers: [AgentToolProvider] = [], home: URL = SupportPaths.home) {
        self.backend = backend
        self.level = level
        self.home = home
        tools = Dictionary(AgentTools.all(providers: providers).map { ($0.name, $0) },
                           uniquingKeysWith: { a, _ in a })
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
            let text = await tool.approvalText?(backend, args) ?? name
            guard await ask(client: client, tool: name, text: text) else {
                return deny(tool, client: client)
            }
            // The user may have lowered the level or switched agents off while answering; re-check before running.
            guard enabled, tool.level <= level else {
                return refuse(tool, "the level was lowered or agents were turned off while you answered",
                              client: client)
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

    func ask(client: String, tool: String, text: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let approval = AgentApproval(client: client, text: text, tool: tool,
                                         asked: Date(), answer: continuation)
            pending.append(approval)
            notify(approval)
            timeouts[approval.id] = Task { [weak self, id = approval.id] in
                try? await Task.sleep(for: self?.approvalTimeout ?? .seconds(300))
                self?.answer(id, allow: false)
            }
        }
    }

    func answer(_ id: UUID, allow: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        let approval = pending.remove(at: index)
        AgentNotifier.dismiss(id)
        approval.answer.resume(returning: allow)
    }

    func denyPending() {
        for approval in pending {
            timeouts.removeValue(forKey: approval.id)?.cancel()
            AgentNotifier.dismiss(approval.id)
            approval.answer.resume(returning: false)
        }
        pending.removeAll()
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
        guard let entry = actions.first(where: { $0.id == id }),
              !entry.undone, let undo = entry.undo else { return }
        try await undo()
        // Re-found after the await: the log may have trimmed or grown while the undo ran.
        guard let index = actions.firstIndex(where: { $0.id == id }),
              !actions[index].undone else { return }
        actions[index].undone = true
        record(client: entry.client, tool: entry.tool,
               detail: "undo \(entry.detail)", outcome: .ok, undo: nil)
    }

    private struct ActionLine: Encodable {
        var time: String
        var client: String
        var tool: String
        var detail: String
        var outcome: String
    }

    // The log file keeps the record across restarts; the undo closures cannot.
    private func appendToLog(_ entry: AgentAction) {
        let outcome: String
        switch entry.outcome {
        case .ok: outcome = "ok"
        case .refused(let why): outcome = "refused: \(why)"
        case .denied: outcome = "denied"
        case .error(let why): outcome = "error: \(why)"
        }
        try? JSONLines.append(
            ActionLine(time: AgentTools.stamp.string(from: entry.time), client: entry.client,
                       tool: entry.tool, detail: entry.detail, outcome: outcome),
            to: backend.roots.support.appending(path: "agents/actions.jsonl"))
    }

    private func describe(_ args: JSONValue) -> String {
        guard let object = args.object, !object.isEmpty else { return "" }
        return object.keys.sorted().compactMap { key in
            args[key]?.string ?? args[key]?.int.map(String.init) ?? args[key]?.bool.map { "\($0)" }
        }.joined(separator: " ")
    }

    // MARK: - resources/read

    func readResource(_ uri: String, client: String = "agent") throws -> String {
        let text: JSONValue
        switch uri {
        case "cartouche://status":
            text = [
                "level": .string(level.rawValue),
                "client": .string(client),
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

    // Which tools restore cleanly; installs and deletions cannot be undone.
    private func snapshotUndo(tool: String, args: JSONValue) -> (() async throws -> Void)? {
        let backend = backend
        let gameID = (try? AgentTools.findStrict(backend, args))?.id
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
            guard let was = backend.defaultRunner() else { return nil }
            return { backend.setDefaultRunner(was) }
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
