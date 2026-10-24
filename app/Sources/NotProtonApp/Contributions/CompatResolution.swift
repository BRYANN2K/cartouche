// One resolved answer for the game panel, the library badges and the agent tools.
// Order: applicable Cartouche data, then the last usable Cartouche copy, then compat.json and MacGamingDB for what is
// still missing, then nothing. A valid "not compatible", an explicit absence or a revocation is never replaced by older data.

import Foundation

struct ResolvedCompatibility: Equatable, Sendable {

    enum Origin: Equatable, Sendable {
        case cartouche
        case cartoucheCached
        case legacy
        case none
    }

    enum Verdict: Equatable, Sendable {
        case playable, mixed, needsFix, compatible, limited, notCompatible

        var label: String {
            switch self {
            case .playable: String(localized: "Playable")
            case .mixed: String(localized: "Mixed results")
            case .needsFix: String(localized: "Needs a fix")
            case .compatible: String(localized: "Compatible")
            case .limited: String(localized: "Limited")
            case .notCompatible: String(localized: "Not compatible")
            }
        }
    }

    struct Statement: Equatable, Sendable {
        var verdict: Verdict
        // "Cartouche players", "Official Mac client", "CrossOver 26.3 · CodeWeavers"…
        var source: String
        var notes: String?
        var checkedAt: String?
        var exceptions: [CommunityFeed.ModeException]
    }

    enum AntiCheat: Equatable, Sendable {
        case present([String])
        case absent
        case unknown
    }

    enum Online: Equatable, Sendable {
        case compatible
        case blocked
        case unknown
    }

    var origin: Origin = .none
    var statement: Statement?
    var antiCheat: AntiCheat = .unknown
    var antiCheatFromLinuxSources = false
    // A Mac statement on protected online play; Linux data never fills this
    var macOnline: Online = .unknown
    var cohorts: [CommunityFeed.Cohort] = []
    var fixes: [CommunityFeed.FixRef] = []
    var revokedFixes: [CommunityFeed.FixRef] = []
    var feedGameID: String?

    var hasAntiCheat: Bool {
        if case .present = antiCheat { return true }
        return false
    }

    var antiCheatNames: [String] {
        if case .present(let names) = antiCheat { return names }
        return []
    }

    // The Linux "blocked" badge only when no Mac statement contradicts it
    func showsLinuxBlock(_ linux: AntiCheatSummary?) -> Bool {
        linux?.level == .blocked && macOnline != .compatible
    }

    static func resolve(
        feed: CommunityFeed?, ref: String?, method: PlayMethod, legacy: CompatRecord?, now: Date
    ) -> ResolvedCompatibility {
        var out = ResolvedCompatibility()
        let usable = feed.map { now <= $0.usableUntil } ?? false
        if let feed, usable, let ref, let entry = feed.game(ref) {
            out.origin = now <= feed.refreshAfter.addingTimeInterval(24 * 3600) ? .cartouche : .cartoucheCached
            out.feedGameID = entry.id
            out.cohorts = entry.cohorts.filter {
                $0.configuration.method == method && (ContributionAdapter.date($0.expiresAt) ?? .distantPast) >= now
            }
            out.fixes = entry.fixes.filter { !entry.revokedFixes.contains($0) }
            out.revokedFixes = entry.revokedFixes
            let declaration = method == .native ? entry.declarations.native : entry.declarations.wine
            if let verdict = players(out.cohorts) {
                out.statement = Statement(verdict: verdict, source: String(localized: "Cartouche players"), notes: nil,
                                          checkedAt: out.cohorts.map(\.lastTestedAt).max(), exceptions: declaration?.modeExceptions ?? [])
            } else if let declaration {
                out.statement = Statement(
                    verdict: verdict(declaration), source: declaration.source ?? String(localized: "Declared compatibility"),
                    notes: declaration.notes, checkedAt: declaration.checkedAt, exceptions: declaration.modeExceptions ?? [])
            }
            switch entry.anticheat.state {
            case .present: out.antiCheat = .present(entry.anticheat.names)
            case .absent: out.antiCheat = .absent
            case .unknown: break
            }
            let online = out.cohorts.filter { $0.anticheatMode == "protected-matchmaking" }
            let success = online.reduce(0) { $0 + ($1.anticheatResults["success"] ?? 0) }
            let failure = online.reduce(0) { $0 + ($1.anticheatResults["failure"] ?? 0) }
            if success > 0 && failure == 0 {
                out.macOnline = .compatible
            } else if failure > 0 && success == 0 {
                out.macOnline = .blocked
            } else if declaration?.protectedOnline == "compatible" {
                out.macOnline = .compatible
            } else if declaration?.protectedOnline == "blocked" {
                out.macOnline = .blocked
            }
        }
        // compat.json only fills what Cartouche did not say; an explicit absence stays
        if out.antiCheat == .unknown, let names = legacy?.areweanticheatyet?.anticheats, !names.isEmpty {
            out.antiCheat = .present(names)
            out.antiCheatFromLinuxSources = true
            if out.origin == .none { out.origin = .legacy }
        }
        if out.origin == .none, legacy != nil { out.origin = .legacy }
        return out
    }

    // The site's playerVerdict (backend/src/compat-policy.mjs)
    static func players(_ cohorts: [CommunityFeed.Cohort]) -> Verdict? {
        let outcomes = Set(cohorts.flatMap { $0.outcomes.keys })
        guard !outcomes.isEmpty else { return nil }
        let ok: Set = ["playable", "good"]
        let good = outcomes.allSatisfy { ok.contains($0) }
        let bad = outcomes.allSatisfy { !ok.contains($0) }
        if cohorts.contains(where: \.conflicting) || (!good && !bad) { return .mixed }
        return good ? .playable : .needsFix
    }

    static func verdict(_ d: CommunityFeed.Declaration) -> Verdict {
        switch d.label {
        case "Compatible": .compatible
        case "Limited": .limited
        default: .notCompatible
        }
    }
}
