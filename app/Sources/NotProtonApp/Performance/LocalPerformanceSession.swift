import Foundation

struct LocalPerformanceSession: Sendable {
    let folder: URL
    let counter: URL

    var environment: [String: String] {
        ["CARTOUCHE_FPS_DIR": folder.path(percentEncoded: false),
         "CARTOUCHE_FPS_COUNTER": counter.path(percentEncoded: false)]
    }

    static func begin(appID: Int?, record: InstalledGame, launcher: String,
                      directory: URL = SupportPaths.performance, counter: URL = SupportPaths.fpsCounter,
                      now: Date = Date()) throws -> Self? {
        guard let appID, appID > 0 else { return nil }
        let folder = directory.appending(path: "incoming/\(appID)-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let settings = PerformanceReport.shareable(GameLauncher.exports(in: launcher))
        let display = record.wineVersion.map { "Wine \($0)" } ?? record.runnerID
        let lines = ["app_id=\(appID)", "runner=\(record.runnerID)", "flavor=rosetta",
                     "backend=\(record.backend.rawValue)", "display=\(display)",
                     "started=\(Int(now.timeIntervalSince1970))"]
            + settings.keys.sorted().map { "setting=\($0)=\(settings[$0]!)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: folder.appending(path: PerformanceIncoming.sessionFile), options: .atomic)
        return Self(folder: folder, counter: counter)
    }

    func finish(now: Date = Date()) {
        guard let handle = try? FileHandle(forWritingTo: folder.appending(path: PerformanceIncoming.sessionFile)) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("ended=\(Int(now.timeIntervalSince1970))\n".utf8))
        } catch { AppLog.note("local performance session could not be closed: \(error.localizedDescription)") }
    }
}

extension GameLauncher {
    static let fpsMarker = "# Cartouche local frame counter"

    static var fpsLines: [String] {
        """
        \(fpsMarker)
        if [ -n "${CARTOUCHE_FPS_DIR:-}" ]; then
          fps_result=refused
          fps_marker="$CARTOUCHE_FPS_DIR/probe"
          if [ "${CARTOUCHE_FPS:-1}" != 0 ] && [ -f "${CARTOUCHE_FPS_COUNTER:-}" ]; then
            if DYLD_INSERT_LIBRARIES="$CARTOUCHE_FPS_COUNTER" CARTOUCHE_FPS_PROBE="$fps_marker" \\
              "$WINELOADER" --version > "$CARTOUCHE_FPS_DIR/probe.log" 2>&1 && [ -s "$fps_marker" ]; then
              fps_result=on
              export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:+$DYLD_INSERT_LIBRARIES:}$CARTOUCHE_FPS_COUNTER"
            fi
          fi
          rm -f "$fps_marker"
          printf 'measure=%s\\n' "$fps_result" >> "$CARTOUCHE_FPS_DIR/session"
          echo "fps: $fps_result for this launch"
        fi
        """.components(separatedBy: "\n")
    }

    static func addFrameCounter(to folder: GameFolder) throws {
        guard let text = try? String(contentsOf: folder.launcher, encoding: .utf8), !text.contains(fpsMarker) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("cd ") || $0.hasPrefix("exec ") }) else { return }
        lines.insert(contentsOf: fpsLines, at: index)
        try atomicReplace(folder.launcher, with: Data(lines.joined(separator: "\n").utf8),
                          step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.launcher.path(percentEncoded: false))
    }
}
