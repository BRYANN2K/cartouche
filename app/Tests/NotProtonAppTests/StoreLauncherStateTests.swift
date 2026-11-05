import Foundation
import Testing

@testable import NotProtonApp

private func placeExe(_ launcher: StoreLauncher) {
    try? FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data("MZ".utf8))
}

// What the store pages offer for an official launcher, read from StoreCenter so no test
// needs the screen. Sign-in itself belongs to the model; these tests set its session.
@Suite("Launcher states", .serialized)
@MainActor
struct StoreLauncherStateTests {

    private final class Gate: @unchecked Sendable {
        private let stream = AsyncStream<Void>.makeStream()
        func open() { stream.continuation.finish() }
        func wait() async { for await _ in stream.stream {} }
    }

    private struct Exiting: LauncherRun {
        let status: Int32
        func run(_ command: ClientCommand) async throws -> ClientOutput { ClientOutput(status: 0, stdout: "", stderr: "") }
        func start(_ command: ClientCommand) async throws -> any LauncherProcess { Gone(status: status) }
    }

    private struct Gone: LauncherProcess {
        let status: Int32
        var isRunning: Bool { false }
        func wait() async -> Int32 { status }
        func stop() {}
    }

    private func until(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func disabledEA(_ scene: StoreScene) throws -> EAAdapter {
        var ea = try #require(scene.center.adapter(.ea) as? EAAdapter)
        ea.enabled = false
        return ea
    }

    @Test("A store's availability and its launcher actions answer through the protocol")
    func dispatch() async throws {
        let scene = try await StoreScene("launcher-dispatch")
        defer { scene.remove() }
        let disabled: any StoreAdapter = try disabledEA(scene)
        #expect(!disabled.isAvailable)
        await #expect(throws: StoreError.self) { _ = try await disabled.openLauncher() }
        #expect(try #require(scene.center.adapter(.ubisoft)).officialLauncher != nil)
        #expect(try #require(scene.center.adapter(.gog)).officialLauncher == nil)
    }

    @Test("A disabled EA with a saved session stays signed out and never lists games")
    func eaSessionIgnored() async throws {
        let scene = try await StoreScene("launcher-ea-session")
        defer { scene.remove() }
        try scene.vault.write(StoreSecret(account: "old", files: [:]), for: .ea)
        scene.center.replace(try disabledEA(scene), for: .ea)
        await scene.center.start()
        #expect(scene.center.connection(.ea) == .notConnected)
        #expect(scene.center.launcherState(.ea) == nil)
        #expect(scene.center.launcherStep(.ea) == nil)
        scene.center.installLauncher(.ea)
        #expect(scene.center.launcherActivity[.ea] == nil)
    }

    @Test("Each store keeps its own page: only launchers get launcher steps")
    func steps() async throws {
        let scene = try await StoreScene("launcher-steps")
        defer { scene.remove() }
        #expect(scene.center.launcherStep(.gog) == nil)
        #expect(scene.center.launcherStep(.ubisoft) == .install)
        try scene.seedUbisoft()
        #expect(scene.center.launcherStep(.ubisoft) == .signIn)
        scene.center.signIn = SignInSession(store: .ubisoft, state: .preparing)
        #expect(scene.center.launcherStep(.ubisoft) == .waiting)
        scene.center.signIn = SignInSession(store: .ubisoft, state: .finishing)
        #expect(scene.center.launcherStep(.ubisoft) == .waiting)
        scene.center.signIn = SignInSession(store: .ubisoft, state: .failed("no session"))
        #expect(scene.center.launcherStep(.ubisoft) == .failed("no session", retry: .signIn))
        scene.center.signIn = SignInSession(store: .epic, state: .preparing)
        #expect(scene.center.launcherStep(.ubisoft) == .signIn)
    }

    @Test("Installing goes from download progress to the installer, then to sign-in")
    func install() async throws {
        let scene = try await StoreScene("launcher-install")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        let launcher = try #require(center.adapter(.ubisoft)?.officialLauncher)
        let downloaded = Gate(), installed = Gate()
        center.fetchInstaller = { _, folder, fraction in
            fraction(0.4)
            await downloaded.wait()
            return folder.appending(path: "UbisoftConnectInstaller.exe")
        }
        center.runInstaller = { launcher, file in
            #expect(file.lastPathComponent == "UbisoftConnectInstaller.exe")
            await installed.wait()
            placeExe(launcher)
        }
        center.installLauncher(.ubisoft)
        #expect(center.launcherStep(.ubisoft) == .installing(nil))
        await until { center.launcherStep(.ubisoft) == .installing(0.4) }
        #expect(center.launcherStep(.ubisoft) == .installing(0.4))
        downloaded.open()
        await until { center.launcherState(.ubisoft) == .installing }
        #expect(center.launcherState(.ubisoft) == .installing)
        center.installLauncher(.ubisoft)
        installed.open()
        await until { center.launcherState(.ubisoft) == .ready }
        #expect(center.launcherStep(.ubisoft) == .signIn)
        #expect(launcher.installed)
    }

    @Test("A failed install says why and offers it again; a second try clears it")
    func installFails() async throws {
        let scene = try await StoreScene("launcher-install-fail")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        center.fetchInstaller = { _, _, _ in throw StoreError.failed("no network") }
        center.installLauncher(.ubisoft)
        await until { center.launcherStep(.ubisoft) == .failed("no network", retry: .install) }
        #expect(center.launcherStep(.ubisoft) == .failed("no network", retry: .install))
        center.fetchInstaller = { _, folder, _ in
            placeExe(try #require(await center.adapter(.ubisoft)?.officialLauncher))
            return folder
        }
        center.runInstaller = { _, _ in }
        center.installLauncher(.ubisoft)
        await until { center.launcherStep(.ubisoft) == .signIn }
        #expect(center.launcherStep(.ubisoft) == .signIn)
    }

    @Test("Stopping an install goes back to Install, with no failure")
    func installCancelled() async throws {
        let scene = try await StoreScene("launcher-install-stop")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        center.fetchInstaller = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            throw StoreError.failed("not cancelled")
        }
        center.installLauncher(.ubisoft)
        #expect(center.launcherStep(.ubisoft) == .installing(nil))
        center.cancelLauncherInstall(.ubisoft)
        await until { center.launcherStep(.ubisoft) == .install }
        #expect(center.launcherStep(.ubisoft) == .install)
    }

    @Test("A launcher that won't start shows on its page before sign-in, as a banner after")
    func startFails() async throws {
        let scene = try await StoreScene("launcher-start")
        defer { scene.remove() }
        await scene.center.openLauncher(.ubisoft)
        guard case .failed(let message, retry: .start)? = scene.center.launcherStep(.ubisoft) else {
            Issue.record("\(String(describing: scene.center.launcherStep(.ubisoft)))")
            return
        }
        #expect(message.contains("Ubisoft Connect"))
        #expect(scene.center.problem == nil)

        let signedIn = try await StoreScene("launcher-start-signed-in")
        defer { signedIn.remove() }
        try signedIn.seedUbisoft()
        await signedIn.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        var ubisoft = try #require(signedIn.center.adapter(.ubisoft) as? UbisoftAdapter)
        ubisoft.backing.run = Exiting(status: 3)
        signedIn.center.replace(ubisoft, for: .ubisoft)
        await signedIn.center.openLauncher(.ubisoft)
        await until { signedIn.center.problem != nil }
        #expect(signedIn.center.problem?.contains("Ubisoft Connect") == true)
    }

    @Test("A launcher that exits at once with an error is a failed start; a clean or late exit is not")
    func exits() async throws {
        let scene = try await StoreScene("launcher-exit")
        defer { scene.remove() }
        try scene.seedUbisoft()
        let center: StoreCenter = scene.center
        var ubisoft = try #require(center.adapter(.ubisoft) as? UbisoftAdapter)
        ubisoft.backing.run = Exiting(status: 0)
        center.replace(ubisoft, for: .ubisoft)
        await center.openLauncher(.ubisoft)
        #expect(center.launcherState(.ubisoft) == .ready)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.launcherState(.ubisoft) == .ready)

        ubisoft.backing.run = Exiting(status: 1)
        center.replace(ubisoft, for: .ubisoft)
        await center.openLauncher(.ubisoft)
        await until { center.launcherState(.ubisoft) != .ready }
        if case .startFailed? = center.launcherState(.ubisoft) {} else {
            Issue.record("\(String(describing: center.launcherState(.ubisoft)))")
        }

        center.launcherActivity[.ubisoft] = nil
        var clock = Date()
        center.now = {
            defer { clock.addTimeInterval(3600) }
            return clock
        }
        await center.openLauncher(.ubisoft)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.launcherState(.ubisoft) == .ready)
    }

    @Test("Opening the launcher while it starts shows that it is starting, then clears")
    func opens() async throws {
        let scene = try await StoreScene("launcher-open")
        defer { scene.remove() }
        try scene.seedUbisoft()
        await scene.center.openLauncher(.ubisoft)
        #expect(scene.center.launcherState(.ubisoft) == .ready)
        #expect(scene.calls("ubisoft.launcher").contains { $0.hasPrefix("start ") })
    }

    @Test("The store button opens the store, with no launcher needed")
    func store() async throws {
        let scene = try await StoreScene("launcher-store")
        defer { scene.remove() }
        final class Opened: @unchecked Sendable { var url: URL? }
        let opened = Opened()
        var ubisoft = try #require(scene.center.adapter(.ubisoft) as? UbisoftAdapter)
        ubisoft.openWeb = { opened.url = $0 }
        scene.center.replace(ubisoft, for: .ubisoft)
        await scene.center.openStore(.ubisoft)
        #expect(opened.url == LauncherLinks.storePage(.ubisoft))
        await scene.center.openStore(.gog)
        #expect(scene.center.problem == nil)
    }

    @Test("Launcher actions show in the library only for a signed-in launcher store")
    func signedIn() async throws {
        let scene = try await StoreScene("launcher-signed-in")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        #expect(center.signedInLauncher(.source(.ubisoft)) == nil)
        try scene.seedUbisoft()
        await scene.signIn(.ubisoft, code: "00000000-dead-beef-0000-000000000042")
        await scene.signIn(.epic, code: "epic-good-code")
        #expect(center.signedInLauncher(.source(.ubisoft)) == .ubisoft)
        #expect(center.signedInLauncher(.source(.epic)) == nil)
        #expect(center.signedInLauncher(.all) == nil)
    }

    @Test("EA is off: in no list and not addable; its switch alone brings it back, labelled Experimental")
    func eaOff() async throws {
        let scene = try await StoreScene("ea-off")
        defer { scene.remove() }
        scene.model.addStore(.ea)
        #expect(!CouchNavigator.lists(scene.model).contains(.source(.ea)))
        #expect(!EAAdapter.experimental)
        #expect(!GameSource.offered.contains(.ea))
        #expect(!StoreCenter.offered.contains(.ea))
        #expect(!GameSource.ea.isExperimental)
        #expect(GameSource.offered(ea: true).contains(.ea))
        #expect(GameSource.offered(ea: false).contains(.ubisoft))
    }

    @Test("A launcher with no usable session fails clearly, with no session left and no spinner")
    func eaNoToken() async throws {
        let scene = try await StoreScene("ea-no-token", gogServer: true)
        defer { scene.remove() }
        scene.serveEA()
        let center: StoreCenter = scene.center
        await center.beginSignIn(.ea)
        await center.finishSignIn(.ea, code: "ea-wrong-code")
        guard case .failed(let message)? = center.signIn?.state else { Issue.record("\(String(describing: center.signIn))"); return }
        #expect(!message.isEmpty, "\(message)")
        #expect(center.connection(.ea) == .notConnected)
        #expect(try scene.vault.read(.ea) == nil)
    }

    @Test("A page that never calls back times out with a reason")
    func eaTimeout() async throws {
        let scene = try await StoreScene("ea-timeout")
        defer { scene.remove() }
        let center: StoreCenter = scene.center
        center.sessionPollInterval = 0.01
        center.sessionPollTimeout = 0
        await center.beginSignIn(.ea)
        await until { if case .failed? = center.signIn?.state { true } else { false } }
        guard case .failed(let message)? = center.signIn?.state else { Issue.record("\(String(describing: center.signIn))"); return }
        #expect(message.contains("EA app"))
        #expect(center.connection(.ea) == .notConnected)
    }

    @Test("Port 3216 held by another app stops a launch and names it; the launcher's own Wine does not", arguments: [
        ("Spotify", true), ("node", true), ("another process", true),
        ("wine64-preloader", false), ("wineserver", false), ("EADesktop.exe", false),
    ])
    func portHolder(name: String, blocks: Bool) {
        #expect(EAPreflight.blocks(holder: name) == blocks)
    }

    @Test("Playing an EA game runs the port check first, and its message reaches the banner")
    func eaPlayPreflight() async throws {
        let scene = try await StoreScene("ea-preflight")
        defer { scene.remove() }
        var ea = try #require(scene.center.adapter(.ea) as? EAAdapter)
        ea.backing.eaPreflight = { throw StoreError.failed("The EA app needs port 3216, already used by Spotify.") }
        await #expect(throws: StoreError.self) {
            _ = try await ea.launch("1", install: StoreInstall(path: URL(filePath: "/tmp")), prefix: URL(filePath: "/tmp"), offline: false)
        }
        try scene.seedEA()
        scene.center.replace(ea, for: .ea)
        await scene.center.openLauncher(.ea)
        guard case .failed(let message, retry: .start)? = scene.center.launcherStep(.ea) else {
            Issue.record("\(String(describing: scene.center.launcherStep(.ea)))")
            return
        }
        #expect(message.contains("Spotify"))
    }
}
