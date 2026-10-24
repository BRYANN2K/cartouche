import Foundation
import RetroArchKit

enum AgentCompatJSON {

    static func resolved(_ r: ResolvedCompatibility) -> JSONValue {
        let origin: String = switch r.origin {
        case .cartouche: "cartouche"
        case .cartoucheCached: "cartouche-cached"
        case .legacy: "legacy"
        case .none: "none"
        }
        let antiCheat: JSONValue = switch r.antiCheat {
        case .present(let names): ["state": "present", "names": .array(names.map { .string($0) }),
                                   "names_from_linux_sources": .bool(r.antiCheatFromLinuxSources)]
        case .absent: ["state": "absent"]
        case .unknown: ["state": "unknown"]
        }
        let online: String = switch r.macOnline {
        case .compatible: "compatible"
        case .blocked: "blocked"
        case .unknown: "unknown"
        }
        var out: [String: JSONValue] = [
            "origin": .string(origin),
            "anticheat": antiCheat,
            "protected_online_on_mac": .string(online),
            "published_fixes": .number(Double(r.fixes.count)),
            "player_cohorts": .number(Double(r.cohorts.count)),
        ]
        if let s = r.statement {
            out["verdict"] = .string(s.verdict.label)
            out["source"] = .string(s.source)
            if let notes = s.notes { out["notes"] = .string(notes) }
            out["mode_exceptions"] = .array(s.exceptions.map { ["mode": .string($0.mode), "status": .string($0.status)] })
        }
        return .object(out)
    }
}
