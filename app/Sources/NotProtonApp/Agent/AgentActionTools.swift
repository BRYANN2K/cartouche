import Foundation
import InstallerKit
import RetroArchKit

extension AgentTools {

    // MARK: - Installs (Standard, approved)

    static var install: [AgentTool] {
        [
            AgentTool(
                name: "install_from_store",
                detail: "Install a store game through the store itself. "
                    + "Only Steam is wired today: the tool opens "
                    + "steam://install/<appid>, and Steam shows its own dialog.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "store": ["type": "string", "enum": .array(["steam"])],
                        "game": ["type": "string"],
                    ]),
                    "required": ["store", "game"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { backend, args in
                    (try? findStrict(backend, args)).map { "install \($0.name) from Steam" }
                        ?? "install a game from Steam"
                },
                run: { backend, args in
                    _ = try args.require("store")
                    let game = try findStrict(backend, args)
                    guard let appID = game.steamAppID else {
                        throw AgentToolError("\(game.name) has no Steam app id")
                    }
                    try await backend.launchStore("steam://install/\(appID)")
                    return ["started": .bool(true), "note":
                        .string("Steam shows its own install window for \(game.name).")]
                }
            ),

            AgentTool(
                name: "analyze_installer",
                detail: "Inspect a Windows installer folder or setup.exe the user "
                    + "grants access to: parts found and missing, checksums, the "
                    + "Inno Setup data, the space needed, whether it can install.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["path": ["type": "string"]]),
                    "required": ["path"],
                ]),
                run: { backend, args in
                    let url = try fileArg(args, in: backend)
                    let found = try await backend.analyze(url)
                    var out: [String: JSONValue] = [
                        "name": .string(found.name),
                        "can_install": .bool(found.canInstall),
                        "parts": .number(Double(found.scan.parts.count)),
                        "missing": .array(found.missing.map { .string($0.file) }),
                        "damaged": .array(found.damaged.map { .string($0) }),
                        "space": .object([
                            "installed_bytes": .number(Double(found.space.installed)),
                            "temporary_bytes": .number(Double(found.space.temporary)),
                            "total_bytes": .number(Double(found.space.total)),
                        ]),
                    ]
                    if let inno = found.inno {
                        out["inno"] = .object([
                            "title": inno.title.map { .string($0) } ?? .null,
                            "version": inno.version.map { .string($0) } ?? .null,
                            "languages": .array(inno.languages.map { .string($0) }),
                            "passworded": .bool(inno.passworded),
                            "heavy_decompression": .bool(inno.heavyDecompression),
                            "decompressors": .array(inno.decompressors.map { .string($0) }),
                            "redistributables": .array(inno.redistributables.map { .string($0) }),
                        ])
                    }
                    return .object(out)
                }
            ),

            AgentTool(
                name: "install_from_installer",
                detail: "Install a Windows game from an installer folder the user "
                    + "grants access to. Options: \"runner\" (runner id), \"mode\" "
                    + "(guided|express), \"language\", \"name\", \"app_id\". The "
                    + "job runs in InstallCenter; the user approves it in the app.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "path": ["type": "string"],
                        "options": .object([
                            "type": "object",
                            "properties": .object([
                                "runner": ["type": "string"],
                                "mode": ["type": "string", "enum": .array(["guided", "express"])],
                                "language": ["type": "string"],
                                "name": ["type": "string"],
                                "app_id": ["type": "integer"],
                                "verify_first": ["type": "boolean",
                                    "description": "verify checksums before installing"],
                            ]),
                        ]),
                    ]),
                    "required": ["path"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { backend, args in
                    guard let url = try? fileArg(args, in: backend) else { return "install a game" }
                    let whole: Int64
                    if url.hasDirectoryPath {
                        whole = await Task.detached { FolderSize.bytes(url) }.value
                    } else {
                        whole = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                    let human = ByteCountFormatter.string(fromByteCount: whole, countStyle: .binary)
                    return "install \(url.lastPathComponent) (\(human))"
                },
                run: { backend, args in
                    let url = try fileArg(args, in: backend)
                    let found = try await backend.analyze(url)
                    guard found.canInstall, let setup = found.scan.setup else {
                        throw AgentToolError("this installer cannot run: "
                            + (found.blockingProblems.first ?? "unknown problem"))
                    }
                    let options = args["options"] ?? .object([:])
                    let name = options["name"]?.string ?? found.name
                    let language = options["language"]?.string
                        ?? found.inno?.languages.first { $0.lowercased().hasPrefix("en") }
                        ?? found.inno?.languages.first
                    let mode = options["mode"]?.string == "express" ? InnoCommand.Mode.automatic : .guided
                    let files = [setup] + found.scan.parts.map(\.url)
                        + (found.manifest.map { [$0.source] } ?? [])
                    let setupSize = Int64((try? setup.resourceValues(forKeys: [.fileSizeKey])
                        .fileSize).flatMap { $0 } ?? 0)
                    let request = InstallRequest(
                        setup: setup, source: found.folder, name: name,
                        appID: options["app_id"]?.int, gogID: nil,
                        expectedBytes: found.space.installed,
                        installerBytes: found.scan.totalSize + setupSize,
                        installerFiles: files, manifest: found.manifest)
                    let runnerID = options["runner"]?.string
                        ?? backend.runners().filter(\.isOffered).first?.id
                        ?? backend.runners().first?.id
                    guard let runnerID else { throw AgentToolError("no runner is set up for installs") }
                    var inputs = InstallInputs(runnerID: runnerID, gameName: name, mode: mode, language: language)
                    inputs.verifyFirst = options["verify_first"]?.bool ?? false
                    let id = backend.startInstall(request, inputs: inputs)
                    return ["job": .string(id.uuidString), "title": .string(name), "runner": .string(runnerID)]
                }
            ),

            AgentTool(
                name: "get_install_status",
                detail: "An install job's phase, progress, diagnosis and the "
                    + "fixes it offers. Jobs stay listed after they finish.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["job": ["type": "string"]]),
                    "required": ["job"],
                ]),
                run: { backend, args in job(try jobID(backend, args)) }
            ),

            AgentTool(
                name: "retry_install",
                detail: "Run a failed or stopped install again with fixes: "
                    + "verify_files, fewer_threads, single_thread (decompressors "
                    + "limited to one thread), lower_memory, short_path, "
                    + "other_runner, copy_to_internal_disk, rosetta_only "
                    + "(already the default). The new attempt appears in the "
                    + "install log.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "job": ["type": "string"],
                        "fixes": ["type": "array", "items": .object(["type": "string"])],
                    ]),
                    "required": ["job", "fixes"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let job = try jobID(backend, args)
                    guard [.failed, .stopped].contains(job.phase) else {
                        throw AgentToolError("the job is \(job.phase), not failed or stopped")
                    }
                    var fixes: [RetryFix] = []
                    var applied: [String] = []
                    var copied = false
                    for fix in args["fixes"]?.array?.compactMap(\.string) ?? [] {
                        switch fix {
                        case "verify_files": fixes.append(.verifyFiles)
                        case "fewer_threads": fixes.append(.fewerThreads)
                        case "lower_memory": fixes.append(.lessMemory)
                        case "short_path": fixes.append(.shortPath)
                        case "other_runner": fixes.append(.otherRunner)
                        case "single_thread": job.inputs.threads = 1
                        case "copy_to_internal_disk":
                            // The folder moves next to Cartouche's own installs;
                            // the job runs against the copy.
                            if !copied {
                                copied = true
                                job.moveSource(to: try await backend.copyInstallerToInternal(job.request.source))
                            }
                        case "rosetta_only":
                            // Installs always run under Rosetta already.
                            break
                        default: throw AgentToolError("unknown fix \"\(fix)\"")
                        }
                        applied.append(fix)
                    }
                    try backend.retryInstall(job, fixes: fixes)
                    return ["job": .string(job.id.uuidString), "applied": .array(applied.map { .string($0) }),
                            "phase": .string("\(job.phase)")]
                }
            ),

            AgentTool(
                name: "cancel_install",
                detail: "Stop a waiting or running install job.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["job": ["type": "string"]]),
                    "required": ["job"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let job = try jobID(backend, args)
                    try backend.stopInstall(job)
                    return ["stopped": .bool(true), "job": .string(job.id.uuidString)]
                }
            ),

            AgentTool(
                name: "choose_executable",
                detail: "After an install reaches the choosing phase, pick the exe "
                    + "the game starts with. \"exe\" names a candidate path, or "
                    + "any exe inside the install folder.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "job": ["type": "string"],
                        "game": ["type": "string"],
                        "exe": ["type": "string"],
                    ]),
                    "required": ["exe"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { backend, args in
                    let title = (try? jobID(backend, args))?.title ?? "the game"
                    return "pick \(args["exe"]?.string ?? "an exe") as \(title)'s program"
                },
                run: { backend, args in
                    let job = try jobID(backend, args)
                    let exe = try args.require("exe")
                    let candidate = job.candidates.first { $0.path == exe }
                    let url = candidate.map { URL(filePath: $0.path) } ?? URL(filePath: exe)
                    // A path the candidates do not name must resolve inside
                    // the job's install folder — symlinks and .. included.
                    if candidate == nil {
                        guard let folder = job.installFolder,
                              AgentScan.contains(url, in: [folder]) else {
                            throw AgentToolError("the exe must be inside the game's install folder")
                        }
                    }
                    try backend.finishInstall(job, exe: url)
                    return ["game": .string(job.title), "exe": .string(url.lastPathComponent),
                            "candidates": .array(job.candidates.map { .string($0.path) })]
                }
            ),

            AgentTool(
                name: "cleanup_installer",
                detail: "Send an install job's leftover installer files (setup, "
                    + "parts, checksum file) to the Trash. Only what Cartouche "
                    + "recorded goes; user folders are never emptied.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["job": ["type": "string"]]),
                    "required": ["job"],
                ]),
                level: .standard, approval: true, readOnly: false, destructive: true,
                approvalText: { backend, args in
                    (try? jobID(backend, args)).map {
                        "delete the installer files of \($0.title)" } ?? "delete installer files"
                },
                run: { backend, args in
                    let job = try jobID(backend, args)
                    let bytes = try backend.cleanupInstaller(job.request)
                    return ["trashed": .bool(true),
                            "bytes": .number(Double(bytes))]
                }
            ),
        ]
    }

    // MARK: - Game setup (Standard)

    static var config: [AgentTool] {
        [
            AgentTool(
                name: "launch_game",
                detail: "Start a game. Steam games open their steam:// link, "
                    + "installer games their launch script, console games start "
                    + "in RetroArch through Cartouche. Optional \"setup\" fields "
                    + "are applied first, like set_game_config.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "setup": .object([
                            "type": "object",
                            "properties": .object([
                                "backend": ["type": "string"], "runner": ["type": "string"],
                                "translation": ["type": "string", "enum": .array(["rosetta", "fex"])],
                            ]),
                        ]),
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { backend, args in
                    (try? findStrict(backend, args)).map { "start \($0.name)" } ?? "start a game"
                },
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    if let changes = args["setup"] {
                        var choice = backend.setupChoice(for: game.id)
                        try applySetupChanges(&choice, changes)
                        backend.setSetup(choice, for: game.id)
                    }
                    try await backend.launch(game)
                    return ["launched": .bool(true), "game": .string(game.name)]
                }
            ),

            AgentTool(
                name: "quit_game",
                detail: "Ask a running game to end. Console games quit through "
                    + "RetroArch with their auto save state. PC games launch "
                    + "outside Cartouche, so only an installer game's own "
                    + "wineserver can be asked.",
                schema: gameArg(),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    try await backend.quit(game, force: false)
                    return ["quit": .bool(true), "game": .string(game.name)]
                }
            ),

            AgentTool(
                name: "force_quit",
                detail: "Kill a running game. Console games quit the same way as "
                    + "quit_game; an installer game's wineserver is killed.",
                schema: gameArg(),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    try await backend.quit(game, force: true)
                    return ["killed": .bool(true), "game": .string(game.name)]
                }
            ),

            AgentTool(
                name: "set_game_config",
                detail: "Change a game's setup: \"runner\" (id), \"backend\" "
                    + "(d3dmetal|dxmt|dxvk|wined3d), \"translation\" "
                    + "(rosetta|fex), \"metal_hud\", \"version\" (mac|windows), "
                    + "and \"env\" with \"set\" / \"unset\" maps for the game's "
                    + "Cartouche variables (D3DM_, DXMT_, DXVK_, MTL_, ROSETTA_). "
                    + "The answer shows what changed; Undo restores it.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "config": .object([
                            "type": "object",
                            "properties": .object([
                                "runner": ["type": "string"],
                                "backend": ["type": "string"],
                                "translation": ["type": "string", "enum": .array(["rosetta", "fex"])],
                                "metal_hud": ["type": "boolean"],
                                "version": ["type": "string", "enum": .array(["mac", "windows"])],
                                "env": .object([
                                    "type": "object",
                                    "properties": .object([
                                        "set": ["type": "object"],
                                        "unset": ["type": "array"],
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    "required": ["game", "config"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    var choice = backend.setupChoice(for: game.id)
                    try applySetupChanges(&choice, args["config"] ?? .object([:]))
                    backend.setSetup(choice, for: game.id)
                    let resolution = backend.resolution(for: game)
                    return [
                        "game": .string(game.name),
                        "applied": .bool(true),
                        "resolved": [
                            "runner": resolution.setup.runner.map { .string($0.id) } ?? .null,
                            "backend": resolution.setup.backend.map { .string($0.rawValue) } ?? .null,
                            "translation": .string("\(resolution.setup.translation)"),
                        ],
                        "problems": .array(resolution.problems.map { .string("\($0)") }),
                    ]
                }
            ),

            AgentTool(
                name: "set_version",
                detail: "Pick which version of a Steam game with a macOS build "
                    + "runs: \"mac\" or \"windows\".",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "version": ["type": "string", "enum": .array(["mac", "windows"])],
                    ]),
                    "required": ["game", "version"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let version = try args.require("version")
                    guard backend.hasMacBuild(game) else {
                        throw AgentToolError("\(game.name) has no macOS build")
                    }
                    var choice = backend.setupChoice(for: game.id)
                    choice.version = GameVersion(rawValue: version)
                    backend.setSetup(choice, for: game.id)
                    return ["game": .string(game.name), "version": .string(version)]
                }
            ),

            AgentTool(
                name: "apply_recommended_setup",
                detail: "Apply what the compatibility data says works best: the "
                    + "top translation layer MacGamingDB reports for the game on "
                    + "comparable Macs, and the default runner.",
                schema: gameArg(),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    var choice = backend.setupChoice(for: game.id)
                    var applied: [String] = []
                    if let layer = backend.macEntry(game)?.topLayer,
                       let backend2 = GraphicsBackend(layer) {
                        choice.graphics = backend2
                        applied.append("backend=\(backend2.rawValue)")
                    }
                    backend.setSetup(choice, for: game.id)
                    return ["game": .string(game.name), "applied": .array(applied.map { .string($0) }),
                            "note": applied.isEmpty
                                ? .string("no recommendation the data supports; the current setup stays")
                                : .null]
                }
            ),

            AgentTool(
                name: "set_favorite",
                detail: "Add or remove the game from Favorites.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "on": ["type": "boolean"],
                    ]),
                    "required": ["game", "on"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let on = args["on"]?.bool ?? true
                    backend.setFavorite(game.id, on: on)
                    return ["game": .string(game.name), "favorite": .bool(on)]
                }
            ),

            AgentTool(
                name: "hide_game",
                detail: "Hide the game from the library grid (\"on\": false "
                    + "brings it back).",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "on": ["type": "boolean"],
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let on = args["on"]?.bool ?? true
                    backend.hide(game.id, on: on)
                    return ["game": .string(game.name), "hidden": .bool(on)]
                }
            ),

            AgentTool(
                name: "report_result",
                detail: "Write how the last launch went into the game's notes: "
                    + "\"verdict\" (works|fails|faster|slower) and \"note\".",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "verdict": ["type": "string", "enum": .array(["works", "fails", "faster", "slower"])],
                        "note": ["type": "string"],
                    ]),
                    "required": ["game", "verdict"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    try backend.reportResult(game,
                        verdict: try args.require("verdict"), note: args["note"]?.string)
                    return ["recorded": .bool(true), "game": .string(game.name)]
                }
            ),
        ]
    }

    static func applySetupChanges(_ choice: inout GameSetupChoice, _ changes: JSONValue) throws {
        if let runner = changes["runner"]?.string { choice.runnerID = runner }
        if let backend = changes["backend"]?.string {
            guard let value = GraphicsBackend(rawValue: backend) else {
                throw AgentToolError("unknown backend \"\(backend)\"")
            }
            choice.graphics = value
        }
        if let translation = changes["translation"]?.string {
            guard let value = GameSetupChoice.Translation(rawValue: translation) else {
                throw AgentToolError("unknown translation \"\(translation)\"")
            }
            choice.translation = value
        }
        if let hud = changes["metal_hud"]?.bool { choice.metalHUD = hud }
        if let version = changes["version"]?.string {
            guard let value = GameVersion(rawValue: version) else {
                throw AgentToolError("unknown version \"\(version)\"")
            }
            choice.version = value
        }
        if let env = changes["env"] {
            var environment = choice.environment ?? [:]
            for (name, value) in env["set"]?.object ?? [:] {
                guard let text = value.string else { continue }
                guard GameSetupResolver.isAllowed(name: name, value: text) else {
                    throw AgentToolError("the variable \(name) is not one Cartouche forwards")
                }
                environment[name] = text
            }
            for name in env["unset"]?.array?.compactMap(\.string) ?? [] { environment[name] = nil }
            choice.environment = environment.isEmpty ? nil : environment
        }
    }

    // MARK: - Runners (Standard, approved for installs)

    static var runners: [AgentTool] {
        [
            AgentTool(
                name: "install_runner",
                detail: "Install or repair a Wine runner by id from list_runners. "
                    + "Pinned downloads only; CrossOver itself is never fetched.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["runner": ["type": "string"]]),
                    "required": ["runner"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { _, args in
                    "install the runner \(args["runner"]?.string ?? "")"
                },
                run: { backend, args in
                    let id = try args.require("runner")
                    try await backend.installRunner(id)
                    return ["runner": .string(id), "installed": .bool(true)]
                }
            ),

            AgentTool(
                name: "repair_runner",
                detail: "Check a runner's pinned files and repair what no longer "
                    + "matches, like verify and reinstall in one.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["runner": ["type": "string"]]),
                    "required": ["runner"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { _, args in
                    "repair the runner \(args["runner"]?.string ?? "")"
                },
                run: { backend, args in
                    let id = try args.require("runner")
                    try await backend.repairRunner(id)
                    return ["runner": .string(id), "repaired": .bool(true)]
                }
            ),

            AgentTool(
                name: "set_default_runner",
                detail: "Make a runner the default for every Windows game without "
                    + "its own choice.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["runner": ["type": "string"]]),
                    "required": ["runner"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let id = try args.require("runner")
                    guard backend.runners().contains(where: { $0.id == id }) else {
                        throw AgentToolError("no runner \"\(id)\"")
                    }
                    backend.setDefaultRunner(id)
                    return ["runner": .string(id)]
                }
            ),
        ]
    }

    // MARK: - Console play (Standard, through Cartouche's relay)

    static var console: [AgentTool] {
        [
            AgentTool(
                name: "add_console",
                detail: "Add a console: its libretro core is downloaded and its "
                    + "games appear in the library.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["system": ["type": "string"]]),
                    "required": ["system"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { _, args in
                    "add the console \(args["system"]?.string ?? "")"
                },
                run: { backend, args in
                    let id = try args.require("system")
                    try await backend.addConsole(id)
                    return ["system": .string(id), "added": .bool(true)]
                }
            ),

            AgentTool(
                name: "remove_console",
                detail: "Remove a console: its core is deleted; the games' files "
                    + "stay on disk and their library entries keep play time.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["system": ["type": "string"]]),
                    "required": ["system"],
                ]),
                level: .standard, approval: true, readOnly: false, destructive: true,
                approvalText: { _, args in
                    "remove the console \(args["system"]?.string ?? "")"
                },
                run: { backend, args in
                    let id = try args.require("system")
                    try await backend.removeConsole(id)
                    return ["system": .string(id), "removed": .bool(true)]
                }
            ),

            AgentTool(
                name: "launch_console_game",
                detail: "Start a console game in RetroArch through Cartouche: "
                    + "\"slot\" loads a save state, \"resume\" the auto state "
                    + "from the last quit.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "slot": ["type": "integer"],
                        "resume": ["type": "boolean"],
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, approval: true, readOnly: false,
                approvalText: { backend, args in
                    (try? requireConsole(backend, args)).map { "start \($0.name)" } ?? "start a game"
                },
                run: { backend, args in
                    let game = try requireConsole(backend, args)
                    try await backend.launchConsole(game,
                        slot: args["slot"]?.int, resume: args["resume"]?.bool ?? false)
                    return ["launched": .bool(true), "game": .string(game.name)]
                }
            ),

            AgentTool(
                name: "save_state",
                detail: "Write a save state of the running console game.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["slot": ["type": "integer"]]),
                    "required": ["slot"],
                ]),
                level: .standard, sendsInput: true, readOnly: false,
                run: { backend, args in
                    try await backend.consoleSaveState(try args.requireInt("slot"))
                    return ["saved": .bool(true)]
                }
            ),

            AgentTool(
                name: "load_state",
                detail: "Load a save state into the running console game.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["slot": ["type": "integer"]]),
                    "required": ["slot"],
                ]),
                level: .standard, sendsInput: true, readOnly: false,
                run: { backend, args in
                    try await backend.consoleLoadState(try args.requireInt("slot"))
                    return ["loaded": .bool(true)]
                }
            ),

            AgentTool(
                name: "console_screenshot",
                detail: "A PNG screenshot of the running console game, base64.",
                schema: .object(["type": "object"]),
                level: .standard,
                run: { backend, _ in
                    let png = try await backend.consoleScreenshot()
                    return ["png_base64": .string(png.base64EncodedString()),
                            "bytes": .number(Double(png.count))]
                }
            ),

            AgentTool(
                name: "swap_disc",
                detail: "Switch the disc of a running multi-disc game.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["disc": ["type": "integer"]]),
                    "required": ["disc"],
                ]),
                level: .standard, sendsInput: true, readOnly: false,
                run: { backend, args in
                    try await backend.consoleSwapDisc(try args.requireInt("disc"))
                    return ["disc": .number(Double(try args.requireInt("disc")))]
                }
            ),

            AgentTool(
                name: "set_console_setup",
                detail: "Change a console game's setup: \"core\", \"look\" "
                    + "(original|crt|lcd), \"lower_input_lag\", \"disc\". "
                    + "Applied at once to the running game; Undo restores it.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "core": ["type": "string"],
                        "look": ["type": "string", "enum": .array(["original", "crt", "lcd"])],
                        "lower_input_lag": ["type": "boolean"],
                        "disc": ["type": "integer"],
                    ]),
                    "required": ["game"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    let game = try requireConsole(backend, args)
                    let look = try args["look"]?.string.map { raw -> ConsoleLook in
                        guard let value = ConsoleLook(rawValue: raw) else {
                            throw AgentToolError("unknown look \"\(raw)\"")
                        }
                        return value
                    }
                    if let core = args["core"]?.string,
                       !(ConsoleCatalog.console(game.console)?.cores ?? []).contains(core) {
                        throw AgentToolError("no core \"\(core)\" for \(game.console)")
                    }
                    await backend.setConsoleSetup(game.id) { setup in
                        if let core = args["core"]?.string { setup.core = core }
                        if let look { setup.look = look }
                        if let lag = args["lower_input_lag"]?.bool { setup.lowerInputLag = lag }
                        if let disc = args["disc"]?.int { setup.disc = disc }
                    }
                    let after = backend.consoleGame(game.id)?.setup
                    return ["game": .string(game.name), "setup": [
                        "core": after?.core.map { .string($0) } ?? .null,
                        "look": .string(after?.look.rawValue ?? "original"),
                        "lower_input_lag": .bool(after?.lowerInputLag ?? true),
                        "disc": .number(Double(after?.disc ?? 0)),
                    ]]
                }
            ),

            AgentTool(
                name: "add_console_games",
                detail: "Identify game files the user grants access to and add "
                    + "them to the library. The files stay where they are.",
                schema: .object([
                    "type": "object",
                    "properties": .object(["paths": ["type": "array", "items": .object(["type": "string"])]]),
                    "required": ["paths"],
                ]),
                level: .standard, readOnly: false,
                run: { backend, args in
                    var games: [ConsoleGame] = []
                    var skipped: [String] = []
                    for raw in args["paths"]?.array?.compactMap(\.string) ?? [] {
                        let url = URL(filePath: raw)
                        guard AgentScan.contains(url, in: backend.roots.allowed) else {
                            skipped.append(raw)
                            continue
                        }
                        guard let found = try await backend.identifyFile(url),
                              let game = found.game() else {
                            skipped.append(raw)
                            continue
                        }
                        games.append(game)
                    }
                    try await backend.addConsoleGames(games)
                    return ["added": .number(Double(games.count)),
                            "skipped": .array(skipped.map { .string($0) })]
                }
            ),

            AgentTool(
                name: "scan_game_folders",
                detail: "Scan the game folders the user granted for new console "
                    + "game files and add what the database recognizes.",
                schema: .object(["type": "object"]),
                level: .standard, readOnly: false,
                run: { backend, _ in
                    await backend.rescanFolders()
                    return ["scanned": .bool(true)]
                }
            ),
        ]
    }

    // MARK: - Prefix commands (Full, approved)

    static var full: [AgentTool] {
        [
            AgentTool(
                name: "run_winetricks",
                detail: "Run Winetricks verbs in the game's prefix, like "
                    + "\"vcrun2022\". Destructive verbs (annihilate, prefix=, "
                    + "options) are refused. The run writes winetricks.log.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "verbs": ["type": "array", "items": .object(["type": "string"])],
                    ]),
                    "required": ["game", "verbs"],
                ]),
                level: .full, approval: true, readOnly: false,
                approvalText: { backend, args in
                    let name = (try? findStrict(backend, args))?.name ?? "the game"
                    return "run Winetricks \((args["verbs"]?.array?.compactMap(\.string) ?? []).joined(separator: " ")) in \(name)'s prefix"
                },
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let verbs = args["verbs"]?.array?.compactMap(\.string) ?? []
                    // Installer-game prefixes bypass PrefixTools' own filter;
                    // the check runs here so both paths refuse the same verbs.
                    if let refused = PrefixTools.refusedVerb(verbs) {
                        throw AgentToolError("the verb \(refused) is refused")
                    }
                    let log = try await backend.runWinetricks(game, verbs: verbs)
                    return ["ran": .array(verbs.map { .string($0) }),
                            "log": .string(tail(log, lines: 40, grep: nil))]
                }
            ),

            AgentTool(
                name: "registry_get",
                detail: "Read one Wine registry value of the game's prefix: "
                    + "\"key\" like HKCU\\Software\\Wine\\Direct3D and \"value\".",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "key": ["type": "string"],
                        "value": ["type": "string"],
                    ]),
                    "required": ["game", "key", "value"],
                ]),
                level: .full,
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let out = try await backend.registryGet(game,
                        key: try args.require("key"), value: try args.require("value"))
                    return ["key": .string(try args.require("key")), "value": .string(out)]
                }
            ),

            AgentTool(
                name: "registry_set",
                detail: "Set one Wine registry value of the game's prefix, like "
                    + "winetricks' registry changes. \"key\" is a key path, "
                    + "\"value\" the value name, \"data\" its content, \"type\" "
                    + "(REG_SZ by default).",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "key": ["type": "string"],
                        "value": ["type": "string"],
                        "data": ["type": "string"],
                        "type": ["type": "string", "enum": .array(["REG_SZ", "REG_DWORD", "REG_BINARY"])],
                    ]),
                    "required": ["game", "key", "value", "data"],
                ]),
                level: .full, approval: true, readOnly: false,
                approvalText: { backend, args in
                    let name = (try? findStrict(backend, args))?.name ?? "the game"
                    let key = args["key"]?.string ?? "a key"
                    let value = args["value"]?.string ?? "a value"
                    let data = args["data"]?.string ?? ""
                    let type = args["type"]?.string ?? "REG_SZ"
                    return "set \(key)\\\(value) = \(data) (\(type)) in \(name)'s prefix"
                },
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    try await backend.registrySet(game, key: try args.require("key"),
                        value: try args.require("value"), data: try args.require("data"),
                        type: args["type"]?.string ?? "REG_SZ")
                    return ["set": .bool(true)]
                }
            ),

            AgentTool(
                name: "run_in_prefix",
                detail: "Run an exe, msi, bat or cmd file inside the game's "
                    + "prefix, with optional \"args\". Only files inside the "
                    + "prefix or the app's folders run.",
                schema: .object([
                    "type": "object",
                    "properties": .object([
                        "game": ["type": "string"],
                        "exe": ["type": "string"],
                        "args": ["type": "array", "items": .object(["type": "string"])],
                    ]),
                    "required": ["game", "exe"],
                ]),
                level: .full, approval: true, readOnly: false,
                approvalText: { backend, args in
                    let name = (try? findStrict(backend, args))?.name ?? "the game"
                    return "run \(args["exe"]?.string ?? "a program") in \(name)'s prefix"
                },
                run: { backend, args in
                    let game = try findStrict(backend, args)
                    let exe = URL(filePath: try args.require("exe"))
                    try await backend.runInPrefix(game, exe: exe,
                        args: args["args"]?.array?.compactMap(\.string) ?? [])
                    return ["ran": .string(exe.lastPathComponent)]
                }
            ),
        ]
    }
}
