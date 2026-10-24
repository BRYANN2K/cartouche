//// A live wineserver session on a game's own prefix: the server binary and the
//// WINEPREFIX that -w and -k act on, so ending a session can never reach another game.

import Foundation
import InstallerKit

struct WineSession: Sendable, Equatable {
    let server: URL
    let prefix: URL

    // wineserver needs its prefix and nothing else; the app's own environment stays out.
    var environment: [String: String] { ["WINEPREFIX": prefix.path(percentEncoded: false)] }

    // After a game exits, -w lets the session's helpers settle for this long before -k.
    static let drain: TimeInterval = 15

    // The server's binary is the one the launcher ran the game with — the `export
    // WINESERVER=…` GameLauncher writes — with the record's runner as the answer for
    // a launcher gone or written before the variable was kept.
    static func of(folder: GameFolder, runners: [Runner] = [],
                   runnerRoot: URL = SupportPaths.runners) -> WineSession? {
        guard let record = InstalledGames.record(in: folder) else { return nil }
        let prefix = URL(filePath: record.prefix)
        if let server = launcherServer(in: folder),
           FileManager.default.isExecutableFile(atPath: server.path(percentEncoded: false)) {
            return WineSession(server: server, prefix: prefix)
        }
        guard let runner = runners.first(where: { $0.id == record.runnerID }),
              let wine = InstallRunners.wine(for: runner, runners: runnerRoot)
        else { return nil }
        return WineSession(server: wine.server, prefix: prefix)
    }

    // `export WINESERVER='…'` as GameLauncher.script writes it.
    static func launcherServer(in folder: GameFolder) -> URL? {
        guard let text = try? String(contentsOf: folder.launcher, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: /^export WINESERVER='([^']*)'/) else { continue }
            return URL(filePath: String(match.1))
        }
        return nil
    }
}
