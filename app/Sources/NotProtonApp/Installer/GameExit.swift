import Foundation

// A Windows game that crashed, failed or closed right after it started: the library shows it once,
// with its log and a summary to copy.
struct GameExitNotice: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case crashed
        case exitCode(Int32)
        case quick
    }

    let id: UUID
    let gameID: String
    let name: String
    let reason: Reason
    // The kept backtrace when there is one, else the game's own log
    let log: URL
    let summary: String

    var title: String { String(localized: "\(name) quit unexpectedly") }

    var detail: String {
        switch reason {
        case .crashed: String(localized: "It crashed. Its log keeps the backtrace.")
        case .exitCode(let code): String(localized: "It stopped with exit code \(Int(code)).")
        case .quick: String(localized: "It closed a few seconds after it started.")
        }
    }
}

enum GameExit {

    // A launcher gone sooner than this never got the game going.
    static let quick: TimeInterval = 10
    static let backtraceLines = 80
    static let tailLines = 60

    // Stop, End Wine Session, or a game still running past its launcher (a window, a client in
    // its session) is never unexpected.
    static func reason(status: Int32, stopped: Bool, ranFor: TimeInterval, crashed: Bool,
                       outlived: Bool) -> GameExitNotice.Reason? {
        guard !stopped, !outlived else { return nil }
        if crashed { return .crashed }
        // Many games return a non-zero code after a normal session, so only an early exit counts.
        guard ranFor < quick else { return nil }
        return status != 0 ? .exitCode(status) : .quick
    }

    static func notice(gameID: String, name: String, status: Int32, stopped: Bool, ranFor: TimeInterval,
                       outlived: Bool, folder: GameFolder, crashLog: URL?, home: String) -> GameExitNotice? {
        guard let reason = Self.reason(status: status, stopped: stopped, ranFor: ranFor, crashed: crashLog != nil,
                                       outlived: outlived) else { return nil }
        let text = Self.summary(name: name, reason: reason, status: status, ranFor: ranFor, folder: folder,
                                crashLog: crashLog, home: home)
        return GameExitNotice(id: UUID(), gameID: gameID, name: name, reason: reason,
                              log: crashLog ?? folder.gameLog, summary: text)
    }

    // Copy Summary's text, in English like the crash summary: what ran, how it ended, then the
    // backtrace or the log's tail. Reads files, so it runs off the main actor.
    static func summary(name: String, reason: GameExitNotice.Reason, status: Int32, ranFor: TimeInterval,
                        folder: GameFolder, crashLog: URL?, home: String) -> String {
        var out = "Cartouche game exit summary\n\n"
        out += "Game: \(name)\n"
        out += "Cartouche: \(AppVersion.bundled)\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        if let record = InstalledGames.record(in: folder) {
            out += "Runner: \(record.runnerID)\(record.wineVersion.map { " (Wine \($0))" } ?? "")\n"
            out += "Graphics: \(record.graphics ?? GraphicsBackend.wined3d.rawValue)\n"
        }
        let ending: String
        switch reason {
        case .crashed: ending = "crashed"
        case .exitCode: ending = "exited with an error"
        case .quick: ending = "closed right after it started"
        }
        out += "Ended: \(ending), exit status \(status), after \(Int(ranFor.rounded())) s\n"
        let log = crashLog ?? folder.gameLog
        out += "Log: \(log.path(percentEncoded: false))\n"

        if let crashLog, let tail = CrashReports.tail(of: crashLog, lines: 400), let trace = backtrace(tail) {
            out += "\n--- backtrace ---\n\(trace)\n"
        } else {
            out += "\n--- \(CrashLog.gameLog) (last \(tailLines) lines) ---\n"
            if let tail = CrashReports.tail(of: folder.gameLog, lines: tailLines) {
                out += tail.isEmpty ? "(empty)\n" : (tail.hasSuffix("\n") ? tail : tail + "\n")
            } else {
                out += "(not found)\n"
            }
        }
        return CrashReports.redact(out, home: home)
    }

    // From winedbg's (or Wine's) first crash line on, at most `lines` of it.
    static func backtrace(_ text: String, lines: Int = backtraceLines) -> String? {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = all.firstIndex(where: { CrashLog.isCrash(String($0)) }) else { return nil }
        return all[start...].prefix(lines).joined(separator: "\n")
    }
}
