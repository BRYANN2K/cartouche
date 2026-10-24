// The wire format of backend/src/contracts.ts (reportInput, recipeInput). Fixtures: docs/schema/contributions.
// A value Cartouche did not observe is left out, never filled with a guess.

import Foundation

enum ContributionWire {

    struct Mac: Codable, Equatable, Sendable {
        var model: String?
        var chip: String
        var cpuCores: Int?
        var ramGB: Int
        var macos: String

        enum CodingKeys: String, CodingKey {
            case model, chip, cpuCores = "cpu_cores", ramGB = "ram_gb", macos
        }
    }

    struct Resolution: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
    }

    struct Configuration: Codable, Equatable, Sendable {
        var gameBuild: String?
        var store: String?
        var method: PlayMethod
        var mac: Mac?
        var runner: String?
        var runnerBuild: String?
        var translation: String?
        var backend: String?
        var resolution: Resolution?

        enum CodingKeys: String, CodingKey {
            case gameBuild = "game_build", store, method, mac, runner, runnerBuild = "runner_build", translation, backend,
                 resolution
        }
    }

    enum Outcome: String, Codable, Sendable, CaseIterable, Identifiable {
        case doesNotLaunch = "does-not-launch", menuOnly = "menu-only", unplayable, playable, good

        var id: String { rawValue }

        var label: String {
            switch self {
            case .doesNotLaunch: String(localized: "Doesn’t start")
            case .menuOnly: String(localized: "Menu only")
            case .unplayable: String(localized: "Has problems")
            case .playable: String(localized: "Playable")
            case .good: String(localized: "Plays well")
            }
        }
    }

    enum Controller: String, Codable, Sendable, CaseIterable, Identifiable {
        case notTested = "not-tested", works, partial, broken

        var id: String { rawValue }

        var label: String {
            switch self {
            case .notTested: String(localized: "Not tested")
            case .works: String(localized: "Works")
            case .partial: String(localized: "Partly works")
            case .broken: String(localized: "Doesn’t work")
            }
        }
    }

    struct Performance: Codable, Equatable, Sendable {
        var averageFPS: Double
        var measuredSeconds: Int
        var excludedSeconds: Int?
        var method: String
        var collectorVersion: String

        enum CodingKeys: String, CodingKey {
            case averageFPS = "average_fps", measuredSeconds = "measured_seconds", excludedSeconds = "excluded_seconds",
                 method, collectorVersion = "collector_version"
        }
    }

    struct AntiCheat: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
            case singleplayer, multiplayerUnprotected = "multiplayer-unprotected",
                 protectedMatchmaking = "protected-matchmaking"

            var id: String { rawValue }

            var label: String {
                switch self {
                case .singleplayer: String(localized: "Single player")
                case .multiplayerUnprotected: String(localized: "Unprotected multiplayer")
                case .protectedMatchmaking: String(localized: "Protected matchmaking")
                }
            }
        }

        enum Result: String, Codable, Sendable, CaseIterable, Identifiable {
            case notTested = "not-tested", success, failure, unknown

            var id: String { rawValue }

            var label: String {
                switch self {
                case .notTested: String(localized: "Not tested")
                case .success: String(localized: "Worked")
                case .failure: String(localized: "Refused")
                case .unknown: String(localized: "Not sure")
                }
            }
        }

        var mode: Mode
        var result: Result
        var names: [String]
    }

    struct AppliedFix: Codable, Equatable, Sendable {
        var id: String
        var revision: Int
    }

    struct Consent: Codable, Equatable, Sendable {
        var publishReport = true
        var shareStatistics: Bool
        var license = ContributionWire.license

        enum CodingKeys: String, CodingKey {
            case publishReport = "publish_report", shareStatistics = "share_statistics", license
        }
    }

    static let license = "CC0-1.0"

    struct Report: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var appVersion: String
        var origin: String
        var observedAt: String
        var configuration: Configuration
        var outcome: Outcome
        var crashes: Int
        var controller: Controller
        var comment: String?
        var performance: Performance?
        var anticheat: AntiCheat?
        var appliedFixes: [AppliedFix]
        var consent: Consent

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", appVersion = "app_version", origin, observedAt = "observed_at",
                 configuration, outcome, crashes, controller, comment, performance, anticheat,
                 appliedFixes = "applied_fixes", consent
        }
    }

    struct FixValues: Codable, Equatable, Sendable {
        var backend: String?
        var translation: String?
        var version: String?
        var metalHUD: Bool?

        enum CodingKeys: String, CodingKey {
            case backend, translation, version, metalHUD = "metal_hud"
        }

        var isEmpty: Bool { backend == nil && translation == nil && version == nil && metalHUD == nil }
    }

    struct Operation: Codable, Equatable, Sendable {
        var type = "set_game_config"
        var values: FixValues
    }

    struct AppliesTo: Codable, Equatable, Sendable {
        var platform = "macos"
        var gameBuilds: [String]
        var runnerBuilds: [String]
        var backends: [String]

        enum CodingKeys: String, CodingKey {
            case platform, gameBuilds = "game_builds", runnerBuilds = "runner_builds", backends
        }
    }

    struct Recipe: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var title: String
        var description: String
        var license = ContributionWire.license
        var appliesTo: AppliesTo
        var requires: [String] = []
        var conflicts: [String] = []
        var operations: [Operation]
        var validationReportIDs: [String]
        var consentPublish = true

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", title, description, license, appliesTo = "applies_to", requires,
                 conflicts, operations, validationReportIDs = "validation_report_ids", consentPublish = "consent_publish"
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

// The game a contribution is about, by exact store identity
struct ContributionGame: Codable, Equatable, Hashable, Sendable {
    var store: String
    var storeID: String
    var title: String

    var ref: String { "\(store):\(storeID)" }

    enum Resolution: Equatable, Sendable {
        case exact(ContributionGame)
        // A Steam ID found by title for a game installed outside Steam: the user confirms it first
        case needsConfirmation(ContributionGame)
        case unknown
    }

    static func resolve(_ game: Game) -> Resolution {
        switch game.source {
        case .steam:
            guard let appID = game.steamAppID else { return .unknown }
            return .exact(ContributionGame(store: "steam", storeID: String(appID), title: game.name))
        case .epic, .gog, .amazon:
            let prefix = game.source.id + ":"
            guard game.id.hasPrefix(prefix) else { return .unknown }
            let id = String(game.id.dropFirst(prefix.count))
            guard ContributionLabel.isStoreID(id) else { return .unknown }
            return .exact(ContributionGame(store: game.source.id, storeID: id, title: game.name))
        case .installer:
            guard let appID = game.steamAppID ?? game.compatAppID else { return .unknown }
            return .needsConfirmation(ContributionGame(store: "steam", storeID: String(appID), title: game.name))
        case .console:
            return .unknown
        }
    }
}

enum ContributionLabel {

    // backend/src/contracts.ts label(): letters, digits and " .,_+()':-", at most 100 characters
    static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 100,
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                  || " .,_+()':-".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }

    static func isStoreID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0)) }
    }
}

struct MacInfo: Equatable, Sendable {
    var model: String?
    var chip: String?
    var cpuCores: Int?
    var ramGB: Int
    var macOS: String

    static func current() -> MacInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MacInfo(
            model: sysctl("hw.model"), chip: MacChip.current(), cpuCores: sysctlInt("hw.physicalcpu"),
            ramGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    var wire: ContributionWire.Mac? {
        guard let chip = ContributionLabel.clean(chip), let macos = ContributionLabel.clean(macOS), ramGB >= 1 else { return nil }
        return ContributionWire.Mac(model: ContributionLabel.clean(model), chip: chip,
                                    cpuCores: cpuCores.flatMap { (1...256).contains($0) ? $0 : nil }, ramGB: ramGB, macos: macos)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

// What the share sheet collected; the adapter turns it into the backend's report
struct ReportDraft: Equatable, Sendable {
    struct Measured: Equatable, Sendable {
        var averageFPS: Double
        var measuredSeconds: Int
        var excludedSeconds: Int?
        var width: Int?
        var height: Int?
        var ended: Date
    }

    var game: ContributionGame
    var method: PlayMethod
    var runner: String?
    var runnerBuild: String?
    var translation: GameSetupChoice.Translation?
    var backend: GraphicsBackend?
    var gameBuild: String?
    var measured: Measured?
    var outcome: ContributionWire.Outcome = .playable
    var crashes = 0
    var controller: ContributionWire.Controller = .notTested
    var comment = ""
    // Only offered when the game has an identified anti-cheat
    var antiCheatNames: [String] = []
    var antiCheat: ContributionWire.AntiCheat?
    var appliedFixes: [ContributionWire.AppliedFix] = []
    var shareStatistics = false
    var observedAt: Date

    // A finished Steam Play session: always Wine, measured per second by the overlay counter
    static func from(session: StoredSession, game: ContributionGame, excludedSeconds: Int?) -> ReportDraft {
        let runner = session.runnerName.components(separatedBy: " · ").first ?? session.runnerName
        let measured = session.measured.average.map {
            Measured(averageFPS: $0, measuredSeconds: session.measured.seconds, excludedSeconds: excludedSeconds,
                     width: session.measured.width, height: session.measured.height, ended: session.ended)
        }
        return ReportDraft(
            game: game, method: .wine, runner: runner,
            runnerBuild: session.setup.runnerID == PlaySetup.unknownRunnerID ? nil : session.setup.runnerID,
            translation: session.setup.translation, backend: session.setup.backend, measured: measured,
            observedAt: session.ended)
    }
}

enum ContributionAdapter {

    static let collector = "cartouche-fps-1"

    static func report(_ draft: ReportDraft, mac: MacInfo, appVersion: String) -> ContributionWire.Report {
        var configuration = ContributionWire.Configuration(
            gameBuild: ContributionLabel.clean(draft.gameBuild), store: draft.game.store, method: draft.method,
            runner: draft.method == .native ? nil : ContributionLabel.clean(draft.runner),
            runnerBuild: draft.method == .native ? nil : ContributionLabel.clean(draft.runnerBuild),
            translation: draft.method == .native ? "native" : draft.translation?.rawValue,
            backend: draft.method == .native ? "native" : draft.backend?.rawValue)
        var performance: ContributionWire.Performance?
        if draft.shareStatistics {
            configuration.mac = mac.wire
            if let m = draft.measured, m.measuredSeconds >= 1, m.measuredSeconds <= 86400, m.averageFPS.isFinite,
               (0...2000).contains(m.averageFPS) {
                // Second buckets: the 1% low of these buckets is not a frame-time 1% low, so none is sent
                performance = ContributionWire.Performance(
                    averageFPS: (m.averageFPS * 10).rounded() / 10, measuredSeconds: m.measuredSeconds,
                    excludedSeconds: m.excludedSeconds.map { min(max(0, $0), 86400) }, method: "second-buckets-v1",
                    collectorVersion: collector)
                if let w = m.width, let h = m.height, (320...16384).contains(w), (200...16384).contains(h) {
                    configuration.resolution = ContributionWire.Resolution(width: w, height: h)
                }
            }
        }
        let comment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = draft.antiCheatNames.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 100 }
        return ContributionWire.Report(
            appVersion: ContributionLabel.clean(appVersion) ?? "unknown", origin: performance == nil ? "manual" : "app-measured",
            observedAt: iso(min(draft.observedAt, Date())), configuration: configuration, outcome: draft.outcome,
            crashes: min(max(0, draft.crashes), 10000), controller: draft.controller,
            comment: comment.isEmpty ? nil : String(comment.prefix(2000)), performance: performance,
            anticheat: names.isEmpty ? nil : draft.antiCheat.map { var a = $0; a.names = Array(names.prefix(10)); return a },
            appliedFixes: Array(draft.appliedFixes.prefix(20)),
            consent: ContributionWire.Consent(shareStatistics: draft.shareStatistics))
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

// The setting changes a fix proposes, limited to what recipeInput can carry
struct FixDraft: Equatable, Sendable {
    var game: ContributionGame
    var title = ""
    var problem = ""
    var conditions = ""
    var values: ContributionWire.FixValues
    var runnerBuild: String?
    var backend: String
    var gameBuild: String?
    var validationReportIDs: [String] = []

    enum Missing: Equatable, Sendable {
        case title, problem, settings, runner
    }

    var missing: [Missing] {
        var out: [Missing] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.title) }
        if problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.problem) }
        if values.isEmpty { out.append(.settings) }
        if ContributionLabel.clean(runnerBuild) == nil { out.append(.runner) }
        return out
    }

    // The resolved setup of the game, so the fix says what actually runs; the version only when the game has a Mac build
    static func from(setup: GameSetup, game: ContributionGame, hasMacBuild: Bool, gameBuild: String?) -> FixDraft {
        let native = setup.version == .mac && hasMacBuild
        var values = ContributionWire.FixValues()
        if hasMacBuild { values.version = setup.version.rawValue }
        if !native {
            values.backend = setup.backend?.rawValue
            values.translation = setup.translation.rawValue
            values.metalHUD = setup.metalHUD ? true : nil
        }
        return FixDraft(game: game, values: values, runnerBuild: native ? "native" : setup.runner?.id,
                        backend: native ? "native" : setup.backend?.rawValue ?? "other", gameBuild: gameBuild)
    }

    func recipe() -> ContributionWire.Recipe {
        var description = String(localized: "Problem solved: \(problem.trimmingCharacters(in: .whitespacesAndNewlines))")
        let conditions = conditions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conditions.isEmpty { description += "\n" + String(localized: "Worked with: \(conditions)") }
        return ContributionWire.Recipe(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
            description: String(description.prefix(2000)),
            appliesTo: ContributionWire.AppliesTo(
                gameBuilds: ContributionLabel.clean(gameBuild).map { [$0] } ?? [],
                runnerBuilds: ContributionLabel.clean(runnerBuild).map { [$0] } ?? [],
                backends: [backend]),
            operations: [ContributionWire.Operation(values: values)],
            validationReportIDs: Array(validationReportIDs.prefix(30)))
    }
}
