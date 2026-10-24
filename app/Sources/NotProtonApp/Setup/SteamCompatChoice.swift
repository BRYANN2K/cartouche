// A game's compatibility tool as Steam sees it. Cartouche asks by leaving a request the dylib applies inside Steam through
// the Properties > Compatibility call, and reads Steam's choice back from config.vdf.

import Foundation

enum SteamCompatChoice {

    // appid to tool name; an empty name clears the forced tool, app 0 is Steam's default
    static func pending(file: URL = SupportPaths.compatRequests) -> [Int: String] {
        table(file)
    }

    // Asks Steam for this tool, or none with nil. App 0 is the tool every other Windows game gets and is never cleared;
    // a later request for the same game replaces an unapplied one.
    static func request(appID: Int, tool: String?, file: URL = SupportPaths.compatRequests, now: Date = Date()) throws {
        guard appID >= 0, appID <= Int(UInt32.max), appID > 0 || tool != nil else { return }
        if let tool, !isCartoucheTool(tool) { return }
        var all = pending(file: file)
        all[appID] = tool ?? ""
        try write(all, to: file)
        // When it was asked, so an older config.vdf does not undo it once the dylib applied it
        let record = askedFile(beside: file)
        var times = table(record)
        times[appID] = String(Int(now.timeIntervalSince1970))
        try write(times, to: record)
    }

    static func askedFile(beside file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: file.lastPathComponent + "-asked")
    }

    static func asked(file: URL = SupportPaths.compatRequests) -> [Int: Date] {
        table(askedFile(beside: file)).compactMapValues { Int($0).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    private static func table(_ file: URL) -> [Int: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [Int: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let appID = Int(fields[0]), appID >= 0 else { continue }
            out[appID] = String(fields[1])
        }
        return out
    }

    private static func write(_ table: [Int: String], to file: URL) throws {
        let text = table.keys.sorted().map { "\($0)\t\(table[$0]!)\n" }.joined()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(file, with: Data(text.utf8), step: String(localized: "Update compatibility tools"))
    }

    static func modified(config: URL = configFile) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: config.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    // The dylib maps only Cartouche's own tools, named as cartouche_identity.h says
    static func isCartoucheTool(_ name: String) -> Bool {
        name.hasPrefix(SupportPaths.toolPrefix) && name.count < 64
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    static var configFile: URL { SupportPaths.Steam.userData.appending(path: "config/config.vdf") }

    // Steam's per-game tool choices, appid to tool name. Key 0 is the global default.
    static func mappings(config: URL = configFile) -> [Int: String] {
        guard let map = VDF.read(config)?[path: "InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
        else { return [:] }
        var out: [Int: String] = [:]
        for (key, entry) in map.entries {
            guard let appID = Int(key), appID > 0, let name = entry["name"]?.string, !name.isEmpty else { continue }
            out[appID] = name
        }
        return out
    }
}

enum GameSetupApplier {

    struct Outcome: Equatable, Sendable {
        // nil asks Steam for no forced tool
        var tool: String?
        var environment: [String: String]
    }

    // The pair for this setup, nil for the Mac version or when no pair matches
    static func tool(for setup: GameSetup, in tools: [BackendTool]) -> BackendTool? {
        guard setup.version == .windows, let runner = setup.runner, let backend = setup.backend else { return nil }
        let build = runner.build?.id ?? runner.id
        let flavor: CompatTool.Flavor = setup.translation == .fex ? .fex : .rosetta
        return tools.first { $0.build == build && $0.flavor == flavor && $0.backend == backend }
    }

    static func choice(fromTool name: String, in tools: [BackendTool], runners: [Runner]) -> GameSetupChoice? {
        guard let pair = tools.first(where: { $0.name == name }),
              let runner = runners.first(where: { ($0.build?.id ?? $0.id) == pair.build })
        else { return nil }
        return GameSetupChoice(runnerID: runner.id, graphics: pair.backend,
                               translation: pair.flavor == .fex ? .fex : .rosetta, version: .windows)
    }

    @discardableResult
    static func apply(
        _ setup: GameSetup, appID: Int, tools: [BackendTool],
        requests: URL = SupportPaths.compatRequests, setups: URL = SupportPaths.setups
    ) throws -> Outcome {
        let pair = tool(for: setup, in: tools)
        // The Windows version with no matching pair leaves Steam's choice alone
        if setup.version == .mac || pair != nil {
            try SteamCompatChoice.request(appID: appID, tool: pair?.name, file: requests)
        }
        let environment = setup.version == .windows ? setup.environment : [:]
        try writeEnvironment(environment, appID: appID, setups: setups)
        return Outcome(tool: pair?.name, environment: environment)
    }

    // setups/<appid>.env, NAME=value lines the run script reads at launch
    static func writeEnvironment(_ environment: [String: String], appID: Int, setups: URL = SupportPaths.setups) throws {
        let file = setups.appending(path: "\(appID).env")
        let lines = environment.filter { GameSetupResolver.isAllowed(name: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: setups, withIntermediateDirectories: true)
        try atomicReplace(file, with: Data(lines.joined().utf8), step: String(localized: "Save the game’s setup"))
    }
}
