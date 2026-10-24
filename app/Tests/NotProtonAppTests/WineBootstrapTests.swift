import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// The first-boot phase "Preparing Windows environment" against a fake Wine: the loader records its
// call, fakes wineboot -u however the test asks, and bin/wineserver answers -w right away.
@Suite("First boot")
struct WineBootstrapTests {

    struct FakeWine {
        let wine: WineRunner
        let calls: URL
        let serverCalls: URL
    }

    // wineboot: "ok" makes the prefix and exits 0, "fail" exits 1, "slow" sleeps for stop or timeout.
    static func fakeWine(in work: URL, wineboot: String = "ok") throws -> FakeWine {
        let fm = FileManager.default
        let root = work.appending(path: "wine-crossover")
        let calls = work.appending(path: "wine.calls")
        let serverCalls = work.appending(path: "server.calls")

        let behavior: String
        switch wineboot {
        case "fail": behavior = "exit 1"
        case "slow": behavior = "sleep 30; exit 0"
        default: behavior = "mkdir -p \"$WINEPREFIX/drive_c\"; touch \"$WINEPREFIX/system.reg\"; exit 0"
        }
        let loader = root.appending(path: "bin/wine")
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("""
            #!/bin/sh
            echo "$*" >> '\(calls.path)'
            if [ "$1" = wineboot ]; then \(behavior); fi
            exit 0
            """).utf8).write(to: loader)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)

        let server = root.appending(path: "bin/wineserver")
        try Data("#!/bin/sh\necho \"$*\" >> '\(serverCalls.path)'\nexit 0\n".utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        return FakeWine(wine: WineRunner(root: root, loader: loader, server: server, dllPath: ""),
                        calls: calls, serverCalls: serverCalls)
    }

    static func calls(_ file: URL) -> [String] {
        (try? String(contentsOf: file, encoding: .utf8))?
            .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("A fresh prefix runs wineboot -u then wineserver -w, and is ready afterwards")
    func success() async throws {
        let work = try scratchDirectory("boot-ok")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work)
        let prefix = work.appending(path: "pfx")

        let boot = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:], log: work.appending(path: "prefix.log"))
        #expect(boot.prepares)
        #expect(await boot.outcome.value == .ready)
        #expect(Self.calls(fake.calls) == ["wineboot -u"], "wineboot -u, not --init")
        #expect(Self.calls(fake.serverCalls) == ["-w"], "wineserver -w waited for the services")
        #expect(Self.exists(prefix.appending(path: WineBootstrap.readyMarker)))
        #expect(!Self.exists(prefix.appending(path: WineBootstrap.bootingMarker)))
        #expect(!WineBootstrap.needsBoot(prefix))

        // Asked again, nothing runs: the marker answers for it.
        let again = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        #expect(!again.prepares)
        #expect(await again.outcome.value == .ready)
        #expect(Self.calls(fake.calls).count == 1)
    }

    @Test("A prefix made before the markers counts as ready from its registry alone")
    func legacyPrefix() async throws {
        let work = try scratchDirectory("boot-legacy")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work)
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: prefix.appending(path: "system.reg"))
        #expect(!WineBootstrap.needsBoot(prefix))
        let boot = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        #expect(!boot.prepares)
        #expect(await boot.outcome.value == .ready)
        #expect(Self.calls(fake.calls).isEmpty)
    }

    @Test("A leftover booting marker means the interrupted prefix is prepared again")
    func interrupted() async throws {
        let work = try scratchDirectory("boot-interrupted")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work)
        let prefix = work.appending(path: "pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("half-made".utf8).write(to: prefix.appending(path: "system.reg"))
        FileManager.default.createFile(atPath: prefix.appending(path: WineBootstrap.bootingMarker)
            .path(percentEncoded: false), contents: Data())
        #expect(WineBootstrap.needsBoot(prefix))
        #expect(await WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:]).outcome.value == .ready)
        #expect(Self.calls(fake.calls) == ["wineboot -u"])
    }

    @Test("A failed wineboot answers failed, keeps the marker, and the next ask retries")
    func failure() async throws {
        let work = try scratchDirectory("boot-fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work, wineboot: "fail")
        let prefix = work.appending(path: "pfx")

        guard case .failed(let detail) = await WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:]).outcome.value
        else { Issue.record("expected failed"); return }
        #expect(detail.contains("wineboot -u"))
        #expect(Self.exists(prefix.appending(path: WineBootstrap.bootingMarker)),
                "the marker keeps the half-made prefix from looking ready")
        #expect(!Self.exists(prefix.appending(path: WineBootstrap.readyMarker)))

        let retry = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        #expect(await retry.outcome.value == .failed("wineboot -u ended with status 1."))
        #expect(Self.calls(fake.calls) == ["wineboot -u", "wineboot -u"], "the retry ran wineboot again")
    }

    @Test("A wineboot that hangs past the timeout answers failed, not ready")
    func timeout() async throws {
        let work = try scratchDirectory("boot-timeout")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work, wineboot: "slow")
        let prefix = work.appending(path: "pfx")
        let outcome = await WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:],
                                                timeout: 0.2, drain: 5).outcome.value
        guard case .failed(let detail) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(detail.contains("time allowed"))
        #expect(!Self.exists(prefix.appending(path: WineBootstrap.readyMarker)))
    }

    @Test("Stopping a boot answers stopped and never starts the game")
    func stopped() async throws {
        let work = try scratchDirectory("boot-stop")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work, wineboot: "slow")
        let prefix = work.appending(path: "pfx")
        let boot = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        // The process takes a moment to register; wait for the run to be there to stop.
        for _ in 0..<200 where boot.run == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(boot.run != nil)
        boot.stop()
        #expect(await boot.outcome.value == .stopped)
        #expect(!Self.exists(prefix.appending(path: WineBootstrap.readyMarker)))
        #expect(Self.calls(fake.serverCalls).isEmpty, "wineserver -w never ran")
    }

    @Test("Two asks for the same prefix share one boot: wineboot runs once, both wait for it")
    func shared() async throws {
        let work = try scratchDirectory("boot-shared")
        defer { try? FileManager.default.removeItem(at: work) }
        let fake = try Self.fakeWine(in: work, wineboot: "slow")
        let prefix = work.appending(path: "pfx")
        let first = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        let second = WineBootstrap.begin(wine: fake.wine, prefix: prefix, base: [:])
        #expect(first === second, "the second ask joins the in-flight boot")
        for _ in 0..<200 where first.run == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.run != nil)
        // Let the script record its call before the stop lands: a kill can beat its first echo.
        for _ in 0..<200 where Self.calls(fake.calls).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        first.stop()
        async let a = first.outcome.value
        async let b = second.outcome.value
        #expect(await [a, b] == [.stopped, .stopped])
        #expect(Self.calls(fake.calls).filter { $0.hasPrefix("wineboot") }.count == 1)
    }
}
