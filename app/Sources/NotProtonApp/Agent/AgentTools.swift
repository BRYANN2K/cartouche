import Foundation
import InstallerKit
import RetroArchKit

// Handlers call the same backend functions the app's own UI uses; AgentService wraps every call in the level, approval and scan checks, so handlers stay plain.
@MainActor
enum AgentTools {

    static func all(providers: [AgentToolProvider] = []) -> [AgentTool] {
        (read + install + config + runners + console + full) + providers.flatMap { $0.tools() }
    }

    // MARK: - Shared JSON shaping

    // Formatters are not Sendable; every caller is on the main actor.
    nonisolated(unsafe) static let stamp = ISO8601DateFormatter()

    static func stamp(_ date: Date?) -> JSONValue {
        date.map { .string(stamp.string(from: $0)) } ?? .null
    }

    static func game(_ game: Game, backend: AgentBackend, detail: Bool = false) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(game.id),
            "name": .string(game.name),
            "source": .string(game.source.id),
            "installed": .bool(game.installed),
            "favorite": .bool(backend.isFavorite(game.id)),
            "hidden": .bool(backend.isHidden(game.id)),
            "playtime_minutes": .number(Double(game.playtimeMinutes)),
            "last_played": stamp(game.lastPlayed),
        ]
        if let appID = game.steamAppID { out["steam_app_id"] = .number(Double(appID)) }
        if let version = game.version { out["version"] = .string(version.rawValue) }
        out["console"] = game.console.map { console in
            .object([
                "system": .string(console.console),
                "core": console.setup.core.map(JSONValue.string) ?? .null,
                "database_name": console.databaseName.map(JSONValue.string) ?? .null,
                "multi_disc": .bool(console.isMultiDisc),
            ])
        } ?? .null
        if detail, let folder = backend.installFolder(of: game) {
            out["install_folder"] = .string(folder.path(percentEncoded: false))
        }
        return .object(out)
    }

    static func find(_ backend: AgentBackend, _ args: JSONValue) throws -> Game {
        let id = try args.require("game")
        guard let game = backend.game(id) ?? backend.games().first(where: {
            $0.name.range(of: id, options: .caseInsensitive) != nil
        }) else { throw AgentToolError("no game \"\(id)\" in the library") }
        return game
    }

    // Write tools get a stricter lookup: the exact id or the only name match — a bare "a" must not pick an arbitrary game for a change the user sees.
    static func findStrict(_ backend: AgentBackend, _ args: JSONValue) throws -> Game {
        let id = try args.require("game")
        if let game = backend.game(id) { return game }
        let named = backend.games().filter {
            $0.name.range(of: id, options: .caseInsensitive) != nil
        }
        if named.count == 1 { return named[0] }
        guard !named.isEmpty else { throw AgentToolError("no game \"\(id)\" in the library") }
        throw AgentToolError("\"\(id)\" matches \(named.count) games: "
            + named.prefix(5).map(\.name).joined(separator: ", "))
    }

    static func requireConsole(_ backend: AgentBackend, _ args: JSONValue) throws -> ConsoleGame {
        let id = try args.require("game")
        guard let game = backend.consoleGame(id) else { throw AgentToolError("no console game \"\(id)\"") }
        return game
    }

    static func session(_ session: StoredSession) -> JSONValue {
        [
            "runner": .string(session.runnerName),
            "runner_id": .string(session.setup.runnerID),
            "translation": .string("\(session.setup.translation)"),
            "backend": session.setup.backend.map { .string($0.rawValue) } ?? .null,
            "started": stamp(session.started),
            "duration": .number(session.duration),
            "average_fps": session.measured.average.map { .number($0) } ?? .null,
            "low1_fps": session.measured.low1.map { .number($0) } ?? .null,
            "measurement": .string("\(session.measurement)"),
            "settings": .object(session.settings.mapValues(JSONValue.string)),
        ]
    }

    static func job(_ job: InstallJob) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(job.id.uuidString),
            "title": .string(job.title),
            "phase": .string("\(job.phase)".prefix(1).lowercased() + "\(job.phase)".dropFirst()),
            "fraction": .number(job.progress.fraction),
            "stuck": .bool(job.isStuck),
            "tried_fixes": .array(job.tried.map { .string($0.rawValue) }),
        ]
        if let problem = job.problem { out["problem"] = .string(problem) }
        if let diagnosis = job.diagnosis {
            out["diagnosis"] = .object([
                "kind": .string(diagnosis.kind.rawValue),
                "causes": .array(diagnosis.causes.map { .string($0.rawValue) }),
                "fixes": .array(diagnosis.fixes.map { .string($0.rawValue) }),
                "exit_code": .number(Double(diagnosis.exitCode)),
                "detail": diagnosis.detail.map { .string($0) } ?? .null,
                "explanation": diagnosis.explanation.map { .string($0.rawValue) } ?? .null,
            ])
        }
        if let prep = job.unpackerPrepInstalled { out["unpacker_prep"] = .bool(prep) }
        if let game = job.game { out["game"] = .string(game.name) }
        return .object(out)
    }

    static func jobID(_ backend: AgentBackend, _ args: JSONValue) throws -> InstallJob {
        let raw = try args.require("job")
        guard let id = UUID(uuidString: raw), let job = backend.installJob(id) else {
            throw AgentToolError("no install job \"\(raw)\"")
        }
        return job
    }

    // Only the last megabyte is read: Wine logs can grow to gigabytes.
    static func tail(_ url: URL, lines n: Int, grep: String?) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: .newlines)
        if let grep, !grep.isEmpty {
            lines = lines.filter { $0.range(of: grep, options: .caseInsensitive) != nil }
        }
        return lines.suffix(max(1, n)).joined(separator: "\n")
    }
}

// One JSON object per line: the action and report logs, where a hand-quoted "\n" in a field would forge extra entries.
enum JSONLines {
    static func append(_ value: some Encodable, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try data.write(to: file)
        }
    }
}
