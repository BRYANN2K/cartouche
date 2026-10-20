// Opt-in sharing of a session's frame rate, off by default. A report carries the Mac (chip, memory, macOS version),
// the setup, the game's settings and the FPS, and nothing else: no account, no path, no Steam ID.

import Foundation

struct PerformanceReport: Codable, Equatable, Sendable {

    struct Mac: Codable, Equatable, Sendable {
        let chip: String
        let memoryGB: Int
        let macOS: String

        static func current() -> Mac {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return Mac(chip: MacChip.current() ?? "Unknown",
                       memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
                       macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        }

        enum CodingKeys: String, CodingKey {
            case chip, memoryGB = "ram_gb", macOS = "macos"
        }
    }

    struct FPS: Codable, Equatable, Sendable {
        let average: Double
        let low1: Double?
        let measuredSeconds: Int

        enum CodingKeys: String, CodingKey {
            case average, low1 = "low_1_percent", measuredSeconds = "measured_seconds"
        }
    }

    let mac: Mac
    let runner: String
    let runnerBuild: String
    let translation: String
    let backend: String?
    let settings: [String: String]
    let fps: FPS

    enum CodingKeys: String, CodingKey {
        case mac, runner, runnerBuild = "runner_build", translation, backend, settings, fps
    }

    // A setting is shared only when its name is one Cartouche sets and its value cannot carry a path or a name
    static func shareable(_ settings: [String: String]) -> [String: String] {
        settings.filter { name, value in
            GameSetupResolver.isAllowed(name: name, value: value) && !name.hasSuffix("_PATH") && !name.contains("LOG")
                && value.count <= 32 && value.allSatisfy { $0.isLetter || $0.isNumber || ".,-_+:".contains($0) }
        }
    }

    static func make(_ session: StoredSession, mac: Mac) -> PerformanceReport? {
        guard let average = session.measured.average else { return nil }
        var settings = shareable(session.settings)
        if let w = session.measured.width, let h = session.measured.height { settings["resolution"] = "\(w)x\(h)" }
        let runner = session.runnerName.components(separatedBy: " · ").first ?? session.runnerName
        return PerformanceReport(
            mac: mac, runner: runner, runnerBuild: session.setup.runnerID,
            translation: session.setup.translation.rawValue, backend: session.setup.backend?.rawValue,
            settings: settings,
            fps: FPS(average: (average * 10).rounded() / 10, low1: session.measured.low1.map { ($0 * 10).rounded() / 10 },
                     measuredSeconds: session.measured.seconds))
    }
}

struct PerformanceSharing: Sendable {

    static let macGamingDB: (@Sendable (Int) -> URL)? = nil

    var endpoint: (@Sendable (Int) -> URL)? = PerformanceSharing.macGamingDB
    var send: @Sendable (URLRequest) async throws -> Void = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }
    }
    var mac: @Sendable () -> PerformanceReport.Mac = { PerformanceReport.Mac.current() }

    var isAvailable: Bool { endpoint != nil }

    func request(for session: StoredSession) -> URLRequest? {
        guard let endpoint, let report = PerformanceReport.make(session, mac: mac()) else { return nil }
        var request = URLRequest(url: endpoint(session.appID))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cartouche/\(AppVersion.bundled)", forHTTPHeaderField: "User-Agent")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try? encoder.encode(report)
        return request
    }

    @discardableResult
    func share(_ sessions: [StoredSession], enabled: Bool) async -> Int {
        guard enabled else { return 0 }
        var sent = 0
        for session in sessions {
            guard let request = request(for: session) else { continue }
            do {
                try await send(request)
                sent += 1
            } catch {
                AppLog.note("performance report for \(session.appID) not sent: \(error.localizedDescription)")
            }
        }
        return sent
    }
}
