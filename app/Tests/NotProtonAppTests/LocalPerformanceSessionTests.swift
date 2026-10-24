import Foundation
import Testing

@testable import NotProtonApp

@Suite("Installer FPS sessions")
struct LocalPerformanceSessionTests {
    @MainActor
    @Test("An existing installer launcher probes safely, records its frames and imports its session", arguments: [true, false])
    func launchAndIngest(accepted: Bool) async throws {
        let work = try scratchDirectory("local-fps")
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = try InstallerSetupTests.installed(in: work.appending(path: "installs"))
        var record = try #require(InstalledGames.record(in: folder))
        record.appID = 1114150
        let loader = work.appending(path: "wine")
        let fakeWine = """
        #!/bin/sh
        if [ "$1" = --version ]; then
          if [ "$PROBE_ACCEPTED" = 1 ]; then printf accepted > "$CARTOUCHE_FPS_PROBE"; fi
          exit 0
        fi
        printf launched > "$CARTOUCHE_FPS_DIR/launched"
        if [ "$PROBE_ACCEPTED" = 1 ]; then
          i=0
          while [ "$i" -lt 100 ]; do
            printf '%s 60 1 1920 1080\n' "$((1790000000 + i))"
            i=$((i + 1))
          done > "$CARTOUCHE_FPS_DIR/samples-42"
        fi
        """
        try Data(fakeWine.utf8).write(to: loader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        let original = "#!/bin/sh\nexport WINELOADER=\(GameLauncher.quote(loader.path))\ncd \(GameLauncher.quote(work.path)) || exit 1\nexec \"$WINELOADER\" game.exe\n"
        try Data(original.utf8).write(to: folder.launcher)
        try GameLauncher.addFrameCounter(to: folder)
        let migrated = try String(contentsOf: folder.launcher, encoding: .utf8)
        try GameLauncher.addFrameCounter(to: folder)
        #expect(try String(contentsOf: folder.launcher, encoding: .utf8) == migrated)

        let counter = work.appending(path: "counter.dylib")
        try Data().write(to: counter)
        let store = PerformanceStore(folder: work.appending(path: "performance"))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let session = try #require(try LocalPerformanceSession.begin(appID: record.appID, record: record,
            launcher: migrated, directory: store.folder, counter: counter, now: start))
        var environment = session.environment
        environment["PROBE_ACCEPTED"] = accepted ? "1" : "0"
        environment["PATH"] = "/usr/bin:/bin"
        let launchEnvironment = environment
        let launched = try await Task.detached {
            try Shell.run("/bin/sh", [folder.launcher.path], environment: launchEnvironment)
        }.value
        #expect(launched.succeeded)
        #expect(FileManager.default.fileExists(atPath: session.folder.appending(path: "launched").path))
        #expect(PerformanceIncoming.read(session.folder, now: start) == .running)
        session.finish(now: start.addingTimeInterval(100))
        let saved = try #require(try store.ingest(now: start.addingTimeInterval(101)).first)
        #expect(saved.appID == 1114150)
        #expect(saved.setup.runnerID == record.runnerID)
        #expect(saved.measurement == (accepted ? .on : .refused))
        #expect(saved.measured.average == (accepted ? 60 : nil))
        #expect(saved.duration == 100)
    }
}
