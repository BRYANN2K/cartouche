import Foundation
import InstallerKit
import RetroArchKit

extension AgentTools {

    // Read tools: they take nothing out of the app but what the user could see, and AgentScan still runs over every answer.
    static var read: [AgentTool] {
        [
            AgentTool(
                name: "list_games",
                detail: "List the games in the Cartouche library: PC stores, "
                    + "installed packages and console games. Filter by name "
                    + "(\"filter\"), source (\"source\": a store id or a console "
                    + "id like \"snes\") or \"installed\".",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "filter": ["type": "string", "description": "name contains"],
                        "source": ["type": "string", "description": "steam, epic, gog, amazon, installer, or a console id"],
                        "installed": ["type": "boolean"],
                    ]),
                ]),
                run: { backend, args in
                    var games = backend.games()
                    if let source = args["source"]?.string {
                        games = games.filter {
                            if case .console(let id) = $0.source { return id == source || $0.source.id == source }
                            return $0.source.id == source
                        }
                    }
                    if let installed = args["installed"]?.bool {
                        games = games.filter { $0.installed == installed }
                    }
                    if let filter = args["filter"]?.string, !filter.isEmpty {
                        games = games.filter { $0.name.range(of: filter, options: .caseInsensitive) != nil }
                    }
                    return [
                        "games": .array(games.sorted { $0.name < $1.name }.map { game($0, backend: backend) }),
                        "count": .number(Double(games.count)),
                    ]
                }
            ),

            AgentTool(
                name: "get_game",
                detail: "One game's full record: source, install state, setup, "
                    + "resolved launch plan, last FPS session, compatibility and "
                    + "console metadata when present.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    var out = AgentTools.game(game, backend: backend, detail: true).object ?? [:]
                    let resolution = backend.resolution(for: game)
                    out["setup"] = [
                        "runner": resolution.setup.runner.map { .string($0.id) } ?? .null,
                        "backend": resolution.setup.backend.map { .string($0.rawValue) } ?? .null,
                        "translation": .string("\(resolution.setup.translation)"),
                        "metal_hud": .bool(resolution.setup.metalHUD),
                        "problems": .array(resolution.problems.map { .string("\($0)") }),
                        "environment": .object(resolution.setup.environment.mapValues { .string($0) }),
                    ]
                    if let last = backend.sessions(game).last {
                        out["last_fps"] = session(last)
                    }
                    if let record = backend.compatRecord(game) {
                        out["compatibility"] = [
                            "protondb": record.protondb.map {
                                .object(["verdict": .string($0.verdict.rawValue),
                                         "works": .number(Double($0.works)),
                                         "reports": .number(Double($0.reports))])
                            } ?? .null,
                            "anticheat": record.areweanticheatyet.map { .string($0.status.rawValue) } ?? .null,
                        ]
                    }
                    if let console = game.console {
                        out["bios"] = await backend.biosStatus(console.console).map { status in
                            .object(["status": .string("\(status.summary)"),
                                     "files": .array(status.files.map {
                                         .object(["name": .string($0.name), "state": .string("\($0.state)")])
                                     })])
                        } ?? .null
                        out["states"] = .array(await backend.states(console).map {
                            .object(["slot": $0.slot.map { .number(Double($0)) } ?? .null,
                                     "written": stamp($0.date)])
                        })
                    }
                    return .object(out)
                }
            ),

            AgentTool(
                name: "search_store",
                detail: "Search a store's catalog: \"installer\" lists "
                    + "installer folders; a store id (steam, epic, gog, "
                    + "amazon) matches games already in the library.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "store": ["type": "string"],
                        "query": ["type": "string"],
                    ]),
                    "required": ["store"],
                ]),
                run: { backend, args in
                    let store = try args.require("store")
                    let query = args["query"]?.string ?? ""
                    switch store {
                    case "installer":
                        let names = (try? FileManager.default.contentsOfDirectory(
                            at: backend.roots.installs, includingPropertiesForKeys: nil))?
                            .filter { $0.hasDirectoryPath }.map(\.lastPathComponent) ?? []
                        let hits = names.filter { query.isEmpty || $0.range(of: query, options: .caseInsensitive) != nil }
                        return ["results": .array(hits.map { .object(["name": .string($0)]) })]
                    default:
                        let hits = backend.games().filter {
                            $0.source.id == store &&
                            (query.isEmpty || $0.name.range(of: query, options: .caseInsensitive) != nil)
                        }
                        return ["results": .array(hits.map { game($0, backend: backend) })]
                    }
                }
            ),

            AgentTool(
                name: "get_game_config",
                detail: "The game's launch setup: chosen runner, backend, "
                    + "translation, Metal HUD, version, environment variables, "
                    + "and what Cartouche will actually use to run it.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    let choice = backend.setupChoice(for: game.id)
                    let resolution = backend.resolution(for: game)
                    return [
                        "choice": [
                            "runner": choice.runnerID.map { .string($0) } ?? .null,
                            "backend": choice.graphics.map { .string($0.rawValue) } ?? .null,
                            "translation": choice.translation.map { .string($0.rawValue) } ?? .null,
                            "metal_hud": choice.metalHUD.map { .bool($0) } ?? .null,
                            "version": choice.version.map { .string($0.rawValue) } ?? .null,
                            "environment": .object((choice.environment ?? [:]).mapValues { .string($0) }),
                        ],
                        "resolved": [
                            "runner": resolution.setup.runner.map { .string($0.id) } ?? .null,
                            "backend": resolution.setup.backend.map { .string($0.rawValue) } ?? .null,
                            "translation": .string("\(resolution.setup.translation)"),
                            "problems": .array(resolution.problems.map { .string("\($0)") }),
                        ],
                    ]
                }
            ),

            AgentTool(
                name: "get_fps_history",
                detail: "Measured FPS sessions for the game, newest last: "
                    + "runner, backend, translation, average and 1% low per run.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    let sessions = backend.sessions(game)
                    return [
                        "game": .string(game.name),
                        "sessions": .array(sessions.map(session)),
                        "count": .number(Double(sessions.count)),
                    ]
                }
            ),

            AgentTool(
                name: "compare_setups",
                detail: "Group the game's measured sessions by setup (runner, "
                    + "backend, translation) with average FPS per group, best first.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    let groups = Dictionary(grouping: backend.sessions(game).filter {
                        $0.measurement == .on && $0.measured.average != nil
                    }) { "\($0.setup.runnerID)|\($0.setup.backend?.rawValue ?? "")|\($0.setup.translation)" }
                    let averages = groups.map { key, group in
                        (key: key, average: group.compactMap { $0.measured.average }.reduce(0, +)
                            / Double(group.count), runs: group.count)
                    }.sorted { $0.average > $1.average }
                    let rows: [JSONValue] = averages.map { key, average, runs in
                        let parts = key.split(separator: "|")
                        return .object([
                            "runner_id": .string(String(parts[0])),
                            "backend": .string(String(parts[1])),
                            "translation": .string(String(parts[2])),
                            "runs": .number(Double(runs)),
                            "average_fps": .number(average),
                        ])
                    }
                    return ["setups": .array(rows), "game": .string(game.name)]
                }
            ),

            AgentTool(
                name: "get_logs",
                detail: "Tail a log for the game or the app. \"source\": "
                    + "wine (game's Wine log), launch (game's run script log), "
                    + "installer (install log), console (RetroArch log), app "
                    + "(Cartouche's own log). \"tail\" lines, \"grep\" filter.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "source": ["type": "string", "enum": .array(["wine", "launch", "installer", "console", "app"])],
                        "tail": ["type": "integer"],
                        "grep": ["type": "string"],
                    ]),
                    "required": ["source"],
                ]),
                run: { backend, args in
                    let source = try args.require("source")
                    let game = try args["game"]?.string.map { _ = $0; return try find(backend, args) }
                    guard let file = backend.logFile(source, for: game) else {
                        throw AgentToolError(game == nil
                            ? "no \"\(source)\" log for the app"
                            : "no \"\(source)\" log for \(game!.name)")
                    }
                    return [
                        "file": .string(file.lastPathComponent),
                        "tail": .string(tail(file, lines: args["tail"]?.int ?? 200,
                                             grep: args["grep"]?.string)),
                    ]
                }
            ),

            AgentTool(
                name: "get_crash_report",
                detail: "The end of the game's launch log: exit code, last "
                    + "errors and the first missing DLL when the log shows one.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    guard let file = backend.logFile("launch", for: game)
                            ?? backend.logFile("wine", for: game) else {
                        throw AgentToolError("no launch log for \(game.name)")
                    }
                    let text = tail(file, lines: 400, grep: nil)
                    let found = AgentDiagnose.diagnose(game: game, log: text, backend: backend)
                    return [
                        "file": .string(file.lastPathComponent),
                        "exit_code": found.exitCode.map { .number(Double($0)) } ?? .null,
                        "problem": .string(found.problem),
                        "tail": .string(text.components(separatedBy: "\n").suffix(40).joined(separator: "\n")),
                    ]
                }
            ),

            AgentTool(
                name: "diagnose",
                detail: "Read the game's last logs and name the likely problem "
                    + "with concrete fixes: the tool to call and its arguments. "
                    + "Fixes are proposals; they do not run by themselves.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    let log = backend.logFile("launch", for: game).flatMap {
                        tail($0, lines: 600, grep: nil)
                    } ?? backend.logFile("wine", for: game).map { tail($0, lines: 600, grep: nil) } ?? ""
                    let found = AgentDiagnose.diagnose(game: game, log: log, backend: backend)
                    return found.json
                }
            ),

            AgentTool(
                name: "suggest_fps_boost",
                detail: "Propose the setup changes most likely to raise FPS for "
                    + "the game, from its own measured sessions, its "
                    + "compatibility reports and the Mac's hardware.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    return ["suggestions": .array(
                        AgentDiagnose.fpsBoosts(game: game, backend: backend).map { $0.json }
                    )]
                }
            ),

            AgentTool(
                name: "get_compatibility",
                detail: "What the community reports for the game: ProtonDB "
                    + "verdict, AppleGamingWiki ratings, MacGamingDB entries and "
                    + "anti-cheat status, plus Cartouche's confidence estimate.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try find(backend, args)
                    guard let record = backend.compatRecord(game) else {
                        throw AgentToolError("no compatibility record for \(game.name)")
                    }
                    var out: [String: JSONValue] = [
                        "game": .string(record.name),
                        "protondb": record.protondb.map {
                            .object(["verdict": .string($0.verdict.rawValue),
                                     "works": .number(Double($0.works)),
                                     "reports": .number(Double($0.reports))])
                        } ?? .null,
                        "applegamingwiki": record.applegamingwiki.map {
                            .object($0.ratings.mapValues { .string($0) })
                        } ?? .null,
                        "anticheat": record.areweanticheatyet.map {
                            .object(["status": .string($0.status.rawValue),
                                     "native": .bool($0.native),
                                     "anticheats": .array($0.anticheats.map { .string($0) })])
                        } ?? .null,
                    ]
                    if let entry = backend.macEntry(game) {
                        out["macgamingdb"] = .object([
                            "rating": entry.rating.map { .string($0.rawValue) } ?? .null,
                            "reviews": .number(Double(entry.reviewCount)),
                            "top_layer": entry.topLayer.map { .string($0.rawValue) } ?? .null,
                        ])
                        if case .estimate(let estimate) = CompatEstimate.compute(
                            reports: entry.reports, method: .wine,
                            chip: MacChip.current(), gpu: backend.gpuStrength()) {
                            out["estimate"] = .object([
                                "rating": .string(estimate.rating.rawValue),
                                "fps": estimate.fps.map { .number(Double($0)) } ?? .null,
                                "reports": .number(Double(estimate.reportCount)),
                            ])
                        }
                    }
                    return .object(out)
                }
            ),

            AgentTool(
                name: "get_mac_info",
                detail: "The Mac Cartouche runs on: chip, RAM, macOS and graphics.",
                schema: .object(["type": "object"]),
                run: { _, _ in
                    var sys = utsname()
                    uname(&sys)
                    let model = withUnsafePointer(to: &sys.machine) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingCString: $0) }
                    } ?? ""
                    return [
                        "chip": MacChip.current().map { .string($0) } ?? .null,
                        "model": .string(model),
                        "ram_gb": .number(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824),
                        "macos": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                    ]
                }
            ),

            AgentTool(
                name: "get_storage",
                detail: "Free space and how much room Cartouche's folders take: "
                    + "support files, installers, runners, RetroArch.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    let folders = [backend.roots.installs, backend.roots.support,
                                   backend.roots.retroarch]
                    // Folder scans can take seconds; keep them off the main actor.
                    let sizes = await Task.detached {
                        folders.map { Double(FolderSize.bytes($0)) }
                    }.value
                    return [
                        "free_bytes": .number(Double(backend.diskFree(at: backend.roots.support) ?? 0)),
                        "installs_bytes": .number(sizes[0]),
                        "support_bytes": .number(sizes[1]),
                        "retroarch_bytes": .number(sizes[2]),
                    ]
                }
            ),

            AgentTool(
                name: "get_activity",
                detail: "What Cartouche is doing right now: running installs "
                    + "with progress and phase, the console game being played.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    var out: [String: JSONValue] = [
                        "installs": .array(backend.installJobs().filter {
                            $0.phase != .ready && $0.phase != .failed && $0.phase != .stopped
                        }.map(job)),
                    ]
                    if let playing = backend.consolePlaying() {
                        out["playing"] = .object(["game": .string(playing.gameID),
                                                  "phase": .string("\(playing.phase)")])
                    }
                    return .object(out)
                }
            ),

            AgentTool(
                name: "get_running",
                detail: "The game running under Cartouche's control. Cartouche "
                    + "tracks console games through RetroArch; PC games launch "
                    + "outside (Steam, a launcher script) so it cannot watch them.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    guard let playing = backend.consolePlaying() else { return ["running": .null] }
                    return ["running": [
                        "game": .string(playing.gameID),
                        "phase": .string("\(playing.phase)"),
                    ]]
                }
            ),

            AgentTool(
                name: "list_runners",
                detail: "The Wine runners Cartouche knows: kind, version, state "
                    + "and flavors, so agents can pick one or fix a broken one.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    ["runners": .array(backend.runners().map { runner in
                        .object([
                            "id": .string(runner.id),
                            "version": .string(runner.version),
                            "kind": .string(runner.kind.rawValue),
                            "state": .string("\(runner.state)"),
                            "flavors": .array(runner.flavors.map { .string($0.rawValue) }),
                        ])
                    })]
                }
            ),

            AgentTool(
                name: "get_prefix_files",
                detail: "List files inside the game's Wine prefix under a "
                    + "relative path (default: drive_c).",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "path": ["type": "string", "description": "relative path inside the prefix"],
                    ]),
                    "required": ["game"],
                ]),
                run: { backend, args in
                    let game = try find(backend, args)
                    guard let prefix = backend.prefixFolder(game) else {
                        throw AgentToolError("\(game.name) has no prefix; launch it once first")
                    }
                    let root = prefix.appending(path: "drive_c")
                    guard let base = args["path"]?.string.map({ root.appending(path: $0) }) ?? .some(root),
                          AgentScan.contains(base, in: [root]) else {
                        throw AgentToolError("the path must stay inside the game's prefix")
                    }
                    let items = (try? FileManager.default.contentsOfDirectory(
                        at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
                    return ["files": .array(items.prefix(200).map { url in
                        .object([
                            "name": .string(url.lastPathComponent),
                            "folder": .bool(url.hasDirectoryPath),
                            "bytes": .number(Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)),
                        ])
                    })]
                }
            ),

            AgentTool(
                name: "list_consoles",
                detail: "Every console Cartouche supports: system id, name, "
                    + "emulation core, whether it was added, its game count and "
                    + "BIOS state.",
                schema: .object(["type": "object"]),
                run: { backend, _ in
                    let added = backend.addedConsoles().map(\.id)
                    var consoles: [JSONValue] = []
                    for console in backend.consoles() {
                        consoles.append(.object([
                            "id": .string(console.id),
                            "name": .string(console.name),
                            "core": .string(console.core),
                            "added": .bool(added.contains(console.id)),
                            "games": .number(Double(backend.consoleGames().filter {
                                $0.console == console.id }.count)),
                            "bios": await backend.biosStatus(console.id).map {
                                .string("\($0.summary)") } ?? .null,
                        ]))
                    }
                    return ["consoles": .array(consoles)]
                }
            ),

            AgentTool(
                name: "get_bios_status",
                detail: "The BIOS files a console needs (names and hashes only — "
                    + "Cartouche never downloads them): found, missing or wrong. "
                    + "Pass a system id or get every added console.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["system": ["type": "string"]]),
                ]),
                run: { backend, args in
                    var statuses: [JSONValue] = []
                    for console in backend.consoles() {
                        if let system = args["system"]?.string, console.id != system { continue }
                        guard let status = await backend.biosStatus(console.id) else { continue }
                        statuses.append(.object([
                            "system": .string(console.id),
                            "status": .string("\(status.summary)"),
                            "files": .array(status.files.map { file in
                                .object([
                                    "name": .string(file.name),
                                    "md5": file.md5.map { .string($0) } ?? .null,
                                    "needed": .bool(file.needed),
                                    "state": .string("\(file.state)"),
                                ])
                            }),
                        ]))
                    }
                    guard !statuses.isEmpty else { throw AgentToolError("no such added console") }
                    return ["systems": .array(statuses)]
                }
            ),

            AgentTool(
                name: "list_states",
                detail: "The save states of a console game: slot number, preview "
                    + "presence and when it was written.",
                schema: gameArg(),
                run: { backend, args in
                    let game = try requireConsole(backend, args)
                    return ["states": .array(await backend.states(game).map {
                        .object([
                            "slot": $0.slot.map { .number(Double($0)) } ?? .null,
                            "auto": .bool($0.isAuto),
                            "written": stamp($0.date),
                            "screenshot": .bool($0.picture != nil),
                        ])
                    })]
                }
            ),

            AgentTool(
                name: "identify_file",
                detail: "Identify a file the user points at: which console it "
                    + "belongs to, from the game database or its file type.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["path": ["type": "string"]]),
                    "required": ["path"],
                ]),
                run: { backend, args in
                    let url = try fileArg(args, in: backend)
                    guard let found = try await backend.identifyFile(url) else {
                        throw AgentToolError("cannot identify \(url.lastPathComponent)")
                    }
                    return [
                        "console": found.console.map { .string($0) } ?? .null,
                        "name": .string(found.name),
                        "database_name": found.databaseName.map { .string($0) } ?? .null,
                        "recognized": .bool(found.isRecognized),
                        "from": found.identifiedBy.map { .string($0.rawValue) } ?? .null,
                    ]
                }
            ),
        ]
    }

    nonisolated static func gameArg() -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(["game": ["type": "string",
                "description": "game id, or a substring of its name"]]),
            "required": ["game"],
        ])
    }

    static func fileArg(_ args: JSONValue, in backend: AgentBackend) throws -> URL {
        let raw = try args.require("path")
        let url = URL(filePath: raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                             isDirectory: &isDirectory) else {
            throw AgentToolError("no such file: \(raw)")
        }
        guard AgentScan.contains(url, in: backend.roots.allowed) else {
            throw AgentToolError("Cartouche may not read outside its own folders and the ones you granted")
        }
        return url
    }
}
