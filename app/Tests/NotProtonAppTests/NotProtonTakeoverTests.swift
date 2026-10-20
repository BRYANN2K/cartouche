import Foundation
import Testing

@testable import NotProtonApp

// The takeover path: Steam that already carries NotProton's dylib is handed to Cartouche
// after an explicit Replace click. Everything here is a scratch fixture, never the real
// /Applications/Steam.app and never the real Application Support.
@Suite("Replace NotProton", .serialized)
struct NotProtonTakeoverTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.withLock { raised = true } }
        var value: Bool { lock.withLock { raised } }
    }

    private struct Fixture {
        let work: URL
        let app: URL
        let support: URL
        let applicationSupport: URL
        let payload: InstallPayload.Located
        let bridgePayload: BridgePayload.Located

        var plist: URL { app.appending(path: "Contents/Info.plist") }
        var macOS: URL { app.appending(path: "Contents/MacOS") }
        var executable: URL { macOS.appending(path: "steam_osx") }
        var otherDylib: URL { macOS.appending(path: SteamBundle.otherDylibName) }
        var deployedDylib: URL { macOS.appending(path: SupportPaths.dylibName) }
        var keep: URL { app.appending(path: "Contents/Resources/keep.txt") }
        var otherBackup: URL {
            applicationSupport.appending(path: "notproton/backups/Info.plist.before-notproton")
        }
        var deployedVersion: URL { support.appending(path: "dylib.version") }
        var backups: URL { support.appending(path: "backups") }
        var bridge: URL { support.appending(path: "bridge") }
        var signatures: URL { support.appending(path: "signatures/macos.arm64") }
        var fonts: URL { support.appending(path: "fonts") }
        var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
        var iconmaker: URL { support.appending(path: "iconmaker") }
        var appinfo: URL { support.appending(path: "appinfo") }
        var runners: URL { support.appending(path: "runners") }
        var modifications: SteamModifications {
            SteamModifications(file: work.appending(path: "steam-bundles.json"),
                               legacyRecord: DeploymentContent.record(beside: deployedVersion))
        }
    }

    private func compile(_ output: URL, dylib: Bool, in root: URL) throws {
        let source = root.appending(path: "main-\(UUID().uuidString).c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try Shell.check("/usr/bin/clang", (dylib ? ["-dynamiclib"] : [])
            + ["-o", output.path(percentEncoded: false), source.path(percentEncoded: false)])
    }

    private func bridgePayload(in work: URL) throws -> BridgePayload.Located {
        let root = work.appending(path: "bridge-src")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sources: [(source: URL, bridgePaths: [String])] = []
        for entry in BridgePayload.entries {
            let url = root.appending(path: entry.resource)
            try Data("stub \(entry.resource)".utf8).write(to: url)
            sources.append((source: url, bridgePaths: entry.bridgePaths))
        }
        return BridgePayload.Located(sources: sources)
    }

    // A Steam.app that NotProton installed into: its dylib sits in MacOS, the plist
    // declares it, and NotProton's own backups folder keeps the pre-install copy.
    private func fixture(backup: Bool = true, extraInserts: [String] = []) throws -> Fixture {
        let files = FileManager.default
        let work = try scratchDirectory("takeover")
        let fixture = Fixture(
            work: work,
            app: work.appending(path: "Steam.app"),
            support: work.appending(path: "Cartouche"),
            applicationSupport: work.appending(path: "Application Support"),
            payload: try installTestPayload(in: work),
            bridgePayload: try bridgePayload(in: work))

        try files.createDirectory(at: fixture.macOS, withIntermediateDirectories: true)
        try files.createDirectory(at: fixture.keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("valve".utf8).write(to: fixture.keep)
        try compile(fixture.executable, dylib: false, in: work)
        try compile(fixture.otherDylib, dylib: true, in: work)

        // Stock Steam's environment plus what NotProton added, plus a key somebody set later
        let insert = ([fixture.otherDylib] + extraInserts.map { URL(filePath: $0) })
            .map { $0.path(percentEncoded: false) }.joined(separator: ":")
        try SteamBundle.writeInfoPlist([
            "CFBundleIdentifier": "com.valvesoftware.steam",
            "CFBundleExecutable": "steam_osx",
            "AddedByNotProton": true,
            SteamBundle.environmentKey: [
                "LC_ALL": "en_US.UTF-8",
                "ADDED_LATER": "kept",
                SteamBundle.insertKey: insert,
                SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue,
            ],
        ], at: fixture.plist)

        if backup {
            // What Steam's plist looked like before NotProton installed
            try files.createDirectory(
                at: fixture.otherBackup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SteamBundle.writeInfoPlist([
                "CFBundleIdentifier": "com.valvesoftware.steam",
                "CFBundleExecutable": "steam_osx",
                SteamBundle.environmentKey: ["LC_ALL": "en_US.UTF-8"],
            ], at: fixture.otherBackup)
        }
        return fixture
    }

    private func install(
        _ fixture: Fixture,
        replacingNotProton: Bool = true,
        running: Bool = false,
        stopped: Flag = Flag()
    ) throws -> InstallOutcome {
        try SteamInstaller.run(
            payload: fixture.payload,
            bridgePayload: fixture.bridgePayload,
            version: "9.9.9-test",
            app: fixture.app,
            bridge: fixture.bridge,
            signatures: fixture.signatures,
            fonts: fixture.fonts,
            overlayShim: fixture.overlayShim,
            iconmaker: fixture.iconmaker,
            appinfo: fixture.appinfo,
            deployedVersion: fixture.deployedVersion,
            backups: fixture.backups,
            compatTools: fixture.work.appending(path: "compatibilitytools.d"),
            lockFolder: fixture.work,
            modifications: fixture.modifications,
            replacingNotProton: replacingNotProton,
            otherToolSupport: fixture.applicationSupport,
            runnerIsRunning: { _ in running },
            verifyRunner: { _, _ in },
            patchRunner: { _, _, _ in },
            stopClient: { _, onStopping in onStopping(); stopped.set(); return true },
            register: { _ in },
            resetInputAccess: {})
    }

    private func environment(_ fixture: Fixture) -> [String: Any] {
        SteamBundle.readInfoPlist(at: fixture.plist)?[SteamBundle.environmentKey] as? [String: Any] ?? [:]
    }

    @Test("Steam whose only foreign insert is NotProton's dylib reads as NotProton's")
    func detectsNotProton() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        let insert = fixture.otherDylib.path(percentEncoded: false)
        #expect(SteamBundle.deployment(bundledVersion: "9.9.9", app: fixture.app, versionFile: fixture.deployedVersion)
            == .notProton(insert: insert))
        #expect(SteamBundle.usesNotProton(in: fixture.app))
    }

    @Test("An unknown tool beside NotProton's still reads as foreign")
    func unknownToolStaysForeign() throws {
        let unknown = "/opt/other/thing.dylib"
        let foreign = try fixture(extraInserts: [unknown])
        defer { try? FileManager.default.removeItem(at: foreign.work) }
        #expect(SteamBundle.deployment(bundledVersion: "9.9.9", app: foreign.app, versionFile: foreign.deployedVersion)
            == .foreign(insert: "\(foreign.otherDylib.path(percentEncoded: false)):\(unknown)"))
        #expect(!SteamBundle.usesNotProton(in: foreign.app))
    }

    @Test("Replace installs Cartouche, removes only NotProton's dylib and keeps every other key")
    func takeoverInstallsCartouche() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let files = FileManager.default
        let stopped = Flag()
        let backupBefore = try Data(contentsOf: fixture.otherBackup)

        let outcome = try install(fixture, stopped: stopped)

        #expect(stopped.value, "Steam was not stopped for the takeover")
        #expect(outcome.replacedNotProton)
        #expect(
            SteamBundle.currentInsert(at: fixture.plist)
                == fixture.deployedDylib.path(percentEncoded: false),
            "the insert still names NotProton's dylib")

        let environment = environment(fixture)
        #expect(environment["LC_ALL"] as? String == "en_US.UTF-8")
        #expect(environment["ADDED_LATER"] as? String == "kept", "an environment key added after NotProton was dropped")
        #expect(environment[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue)

        // The backup NotProton kept was restored, so its own plist edits left with it
        let plist = try #require(SteamBundle.readInfoPlist(at: fixture.plist))
        #expect(plist["AddedByNotProton"] as? Bool == nil, "a key NotProton added survived the backup restore")

        #expect(!files.fileExists(atPath: fixture.otherDylib.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.deployedDylib.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.executable.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.keep.path(percentEncoded: false)),
                "a file that is not NotProton's was removed")

        // NotProton's own data is read, never written
        #expect(try Data(contentsOf: fixture.otherBackup) == backupBefore)

        let holding = try files.contentsOfDirectory(atPath: fixture.backups.path(percentEncoded: false))
            .filter { $0.hasPrefix("takeover-") }
        #expect(holding.isEmpty, "the held files were not cleaned up")

        let signature = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", fixture.app.path(percentEncoded: false)])
        #expect(signature.succeeded, "the bundle does not verify: \(signature.stderr)")
    }

    @Test("Without NotProton's backup the insert is filtered and other entries are kept")
    func takeoverWithoutBackup() throws {
        let fixture = try fixture(backup: false)
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        _ = try install(fixture)

        let environment = environment(fixture)
        #expect(
            SteamBundle.currentInsert(at: fixture.plist)
                == fixture.deployedDylib.path(percentEncoded: false))
        #expect(environment["ADDED_LATER"] as? String == "kept")
        // The plist key NotProton added stays: with no backup there is nothing to restore it from
        #expect(SteamBundle.readInfoPlist(at: fixture.plist)?["AddedByNotProton"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.otherDylib.path(percentEncoded: false)))
    }

    @Test("A running game refuses the takeover before anything is touched")
    func refusedWhileGameRuns() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let runner = SupportPaths.clonedRoot(forBuild: SupportedRunners.all[0].id, runners: fixture.runners)
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let before = try Data(contentsOf: fixture.plist)
        let stopped = Flag()

        let error = try #require(throws: StepFailure.self) {
            try install(fixture, running: true, stopped: stopped)
        }

        #expect(error.detail.contains("is running"))
        #expect(!stopped.value)
        #expect(try Data(contentsOf: fixture.plist) == before)
        #expect(FileManager.default.fileExists(atPath: fixture.otherDylib.path(percentEncoded: false)))
    }

    @Test("A failure mid-sign puts the plist and NotProton's dylib back")
    func failureRestoresPlistAndDylib() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let before = try Data(contentsOf: fixture.plist)
        try FileManager.default.removeItem(at: fixture.executable)

        let error = try #require(throws: StepFailure.self) { try install(fixture) }
        #expect(error.detail.contains("could not be signed"), "stopped before the signing window: \(error.detail)")

        #expect(try Data(contentsOf: fixture.plist) == before, "the takeover edit was left in the plist")
        #expect(
            SteamBundle.currentInsert(at: fixture.plist)
                == fixture.otherDylib.path(percentEncoded: false))
        #expect(
            FileManager.default.fileExists(atPath: fixture.otherDylib.path(percentEncoded: false)),
            "NotProton's dylib was not put back")
        let holding = try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path(percentEncoded: false))
            .filter { $0.hasPrefix("takeover-") }
        #expect(holding.isEmpty, "the held files were not cleaned up")
    }

    @Test("An unknown foreign insert is refused even with the takeover asked for")
    func unknownInsertRefused() throws {
        let unknown = "/opt/other/thing.dylib"
        let fixture = try fixture(extraInserts: [unknown])
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let before = try Data(contentsOf: fixture.plist)

        let error = try #require(throws: StepFailure.self) { try install(fixture) }
        #expect(error.detail.contains("another tool's dylib"))
        #expect(try Data(contentsOf: fixture.plist) == before)
        #expect(FileManager.default.fileExists(atPath: fixture.otherDylib.path(percentEncoded: false)))
    }

    @Test("Without the explicit click NotProton's insert keeps today's refusal")
    func notProtonStillRefusedByDefault() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        let before = try Data(contentsOf: fixture.plist)

        let error = try #require(throws: StepFailure.self) {
            try install(fixture, replacingNotProton: false)
        }
        #expect(error.detail.contains("another tool's dylib (\(fixture.otherDylib.path(percentEncoded: false)))"))
        #expect(try Data(contentsOf: fixture.plist) == before)
    }
}
