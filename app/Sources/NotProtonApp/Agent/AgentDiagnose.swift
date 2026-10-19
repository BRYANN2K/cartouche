import Foundation
import InstallerKit
import RetroArchKit

// What diagnose reads out of a launch or install log, and what it proposes.
// The same parse backs get_crash_report; fixtures drive the tests.
struct AgentDiagnosis: Sendable {
    var problem: String
    var detail: String = ""
    var exitCode: Int?
    var fixes: [Fix] = []

    struct Fix: Sendable {
        var tool: String
        var arguments: JSONValue
        var why: String

        var json: JSONValue {
            ["tool": .string(tool), "arguments": arguments, "why": .string(why)]
        }
    }

    var json: JSONValue {
        var out: [String: JSONValue] = [
            "problem": .string(problem),
            "fixes": .array(fixes.map(\.json)),
        ]
        if !detail.isEmpty { out["detail"] = .string(detail) }
        if let exitCode { out["exit_code"] = .number(Double(exitCode)) }
        return .object(out)
    }
}

@MainActor enum AgentDiagnose {

    // Missing DLLs and common Wine failures, matched against the log tail.
    static let dllPattern = #"err:module:import_dll (?:Library |Loading library )?([A-Za-z0-9_.-]+\.dll)"#

    static func diagnose(game: Game, log: String, backend: AgentBackend) -> AgentDiagnosis {
        var out = AgentDiagnosis(problem: "no obvious failure in the last log")

        if let dll = firstMatch(dllPattern, in: log) {
            out.problem = "missing DLL: \(dll)"
            out.detail = "Wine could not load \(dll), so the game never started."
            // The known fixes: a winetricks verb that ships the DLL family, or a
            // backend change when the DLL is a D3D one the backend provides.
            let verb = dllVerb(dll)
            out.fixes.append(AgentDiagnosis.Fix(
                tool: "run_winetricks", arguments: ["game": .string(game.id), "verbs": [.string(verb)]],
                why: "installs the runtime that ships \(dll)"))
            if isD3D(dll), backend.graphicsChoices(for: game).contains(.dxvk) {
                out.fixes.append(AgentDiagnosis.Fix(
                    tool: "set_game_config", arguments: ["game": .string(game.id), "config": ["backend": "dxvk"]],
                    why: "DXVK provides \(dll) itself"))
            }
            return out
        }
        if let exit = firstMatch(#"[Ee]xit (?:code|status):? (\d+)"#, in: log).flatMap(Int.init), exit != 0 {
            out.problem = "the game exited with status \(exit)"
            out.exitCode = exit
            out.detail = log.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(5).joined(separator: "\n")
        }
        if log.range(of: "unarc.dll|ISDone.dll|isdone", options: .regularExpression) != nil {
            out.problem = "the installer's decompressor failed"
            out.detail = "unarc/ISDone errors are usually memory, threads, or a damaged part."
            out.fixes = [
                AgentDiagnosis.Fix(tool: "retry_install", arguments: ["job": .string("<job id>"), "fixes": [.string("verify_files")]],
                    why: "a damaged part fails again no matter the settings"),
                AgentDiagnosis.Fix(tool: "retry_install", arguments: ["job": .string("<job id>"), "fixes": [.string("single_thread")]],
                    why: "one decompressor thread rules out a threading fault"),
                AgentDiagnosis.Fix(tool: "retry_install", arguments: ["job": .string("<job id>"), "fixes": [.string("lower_memory")]],
                    why: "less memory stops the decompressor running out of RAM"),
            ]
        }
        if log.range(of: "anticheat|easyanticheat|battleye", options: [.regularExpression, .caseInsensitive]) != nil {
            out.problem = "anti-cheat refuses Wine"
            out.detail = "This game's anti-cheat does not allow Wine. Check get_compatibility before trying more fixes."
        }
        if log.range(of: "err:module:(?!import_dll).*load|cannot find", options: .regularExpression) != nil
            && out.problem == "no obvious failure in the last log" {
            out.detail = log.components(separatedBy: "\n").suffix(10).joined(separator: "\n")
        }
        return out
    }

    // A DLL name to the winetricks verb that installs it, where one exists.
    static func dllVerb(_ dll: String) -> String {
        let lower = dll.lowercased()
        if lower.hasPrefix("vcruntime") || lower.hasPrefix("msvcp") || lower.hasPrefix("msvcr") { return "vcrun2022" }
        if lower.hasPrefix("d3dx9") || lower.hasPrefix("xinput") || lower.hasPrefix("xaudio") { return "directx9" }
        if lower.hasPrefix("dotnet") || lower.hasPrefix("mscoree") { return "dotnet48" }
        if lower.hasPrefix("d3dcompiler") { return "d3dcompiler_47" }
        return "vcrun2022"
    }

    static func isD3D(_ dll: String) -> Bool {
        dll.lowercased().hasPrefix("d3d") || dll.lowercased().hasPrefix("dxgi")
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - FPS suggestions

    static func fpsBoosts(game: Game, backend: AgentBackend) -> [AgentDiagnosis.Fix] {
        var fixes: [AgentDiagnosis.Fix] = []
        let sessions = backend.sessions(game).filter { $0.measurement == .on }
        let choice = backend.setupChoice(for: game.id)
        let resolution = backend.resolution(for: game)
        let current = (runner: resolution.setup.runner?.id,
                       backend: resolution.setup.backend,
                       translation: resolution.setup.translation)

        // The game's own sessions say most: the best measured setup wins.
        let bySetup = Dictionary(grouping: sessions.compactMap { session -> (PlaySetup, Double)? in
            session.measured.average.map { (session.setup, $0) }
        }, by: \.0)
        let best = bySetup.max { a, b in
            (a.value.map(\.1).max() ?? 0) < (b.value.map(\.1).max() ?? 0)
        }
        if let best, let average = best.value.map(\.1).max(),
           best.key.runnerID != current.runner || best.key.backend != current.backend
               || best.key.translation != current.translation {
            fixes.append(.init(
                tool: "set_game_config",
                arguments: ["game": .string(game.id), "config": [
                    "runner": .string(best.key.runnerID),
                    "backend": best.key.backend.map { .string($0.rawValue) } ?? .null,
                    "translation": .string(best.key.translation.rawValue),
                ]],
                why: "measured \(Int(average)) FPS with this setup in a past session"))
        }

        // What other Macs report for this game.
        if let top = backend.macEntry(game)?.topLayer, let layer = GraphicsBackend(top),
           layer != current.backend, backend.graphicsChoices(for: game).contains(layer) {
            fixes.append(.init(
                tool: "set_game_config",
                arguments: ["game": .string(game.id), "config": ["backend": .string(layer.rawValue)]],
                why: "MacGamingDB reports favor \(layer.rawValue) for this game"))
        }

        // A Mac version beats every Wine session.
        if backend.hasMacBuild(game), choice.version != .mac {
            fixes.append(.init(
                tool: "set_version", arguments: ["game": .string(game.id), "version": .string("mac")],
                why: "the game has a macOS build, which needs no translation at all"))
        }

        // FEX where the runner serves it and Rosetta measured badly.
        if current.translation == .rosetta,
           backend.translationChoices(for: game).contains(.fex),
           let worst = sessions.compactMap(\.measured.average).min(), worst < 30 {
            fixes.append(.init(
                tool: "set_game_config",
                arguments: ["game": .string(game.id), "config": ["translation": .string("fex")]],
                why: "FEX skips Rosetta for the game's CPU work"))
        }

        // Measure first when there is nothing to compare.
        if sessions.isEmpty, !(resolution.setup.metalHUD) {
            fixes.append(.init(
                tool: "set_game_config",
                arguments: ["game": .string(game.id), "config": ["metal_hud": .bool(true)]],
                why: "no session was measured yet; the Metal HUD counts frames"))
        }
        return fixes
    }
}
