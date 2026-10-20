import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import NotProtonApp

final class FakeGames: GameActivity, Sendable {
    private struct State {
        var running: Int
        var calls = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state: Mutex<State>

    init(runningFor checks: Int = 0) {
        state = Mutex(State(running: checks))
    }

    func isGameRunning() async -> Bool {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.calls += 1
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
        return state.withLock { s in
            guard s.running > 0 else { return false }
            s.running -= 1
            return true
        }
    }

    func firstCall() async {
        await withCheckedContinuation { continuation in
            if state.withLock({ s -> Bool in
                if s.calls > 0 { return true }
                s.waiter = continuation
                return false
            }) { continuation.resume() }
        }
    }
}

@MainActor
final class FakeRelauncher: Relauncher {
    var count = 0
    var succeeds = true
    func relaunch() -> Bool { count += 1; return succeeds }
}

// Each "process" is a fresh center, flow, option and service on one defaults domain.
// Nothing here relaunches anything for real.
@Suite("Relaunch")
@MainActor
struct RelaunchTests {

    struct Copy {
        let center: PermissionCenter
        let flow: PermissionFlow
        let service: RelaunchService
        let remap: GatedOption
        let relauncher: FakeRelauncher
    }

    static let controls = ScreenRoute.controls(game: "Hades", finishing: .inputMonitoring)

    func launch(_ tcc: FakeTCC, _ scratch: ScratchDefaults, games: FakeGames = FakeGames()) async -> Copy {
        let center = makeCenter(tcc, scratch)
        await center.refresh()
        let flow = PermissionFlow(center: center)
        let relauncher = FakeRelauncher()
        let service = RelaunchService(defaults: scratch.defaults, center: center, games: games,
                                      relauncher: relauncher, pollInterval: .milliseconds(5))
        service.watch(flow) { Self.controls }
        let remap = GatedOption(.inputMonitoring, flow: flow)
        remap.onWaitingForRelaunch = { service.markWaiting($0) }
        return Copy(center: center, flow: flow, service: service, remap: remap, relauncher: relauncher)
    }

    @Test("Quit & Reopen: Cartouche reopens on the same Controls screen with remapping on, and no second prompt")
    func quitAndReopen() async throws {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .undetermined])
        let first = await launch(tcc, scratch)

        first.remap.set(true)
        #expect(first.flow.asking?.explanation.relaunch != nil, "the sheet did not say a relaunch is needed")
        await first.flow.confirm()
        #expect(tcc.requests == [.inputMonitoring])

        // The user allows Cartouche, macOS quits it with Quit & Reopen, and it starts again
        tcc.set(.inputMonitoring, .granted)
        let clock = ContinuousClock.now
        let second = await launch(tcc, scratch)
        let route = try #require(second.service.restore())
        if route.finishing == .inputMonitoring { second.remap.finishAfterRelaunch() }
        let elapsed = ContinuousClock.now - clock

        #expect(route == Self.controls)
        #expect(route.screen == "controls" && route.detail == "Hades")
        #expect(second.remap.isOn)
        #expect(second.remap.status == nil)
        #expect(tcc.requests == [.inputMonitoring], "macOS was asked a second time")
        #expect(elapsed < .seconds(5))
        #expect(second.service.restore() == nil, "the screen was restored twice")
    }

    @Test("Later: Controls shows Relaunch Cartouche to finish, the option waits, and the rest keeps working")
    func later() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .undetermined, .notifications: .granted])
        let copy = await launch(tcc, scratch)

        copy.remap.set(true)
        await copy.flow.confirm()
        // macOS's alert, Later: Cartouche keeps running and comes back to the front
        tcc.set(.inputMonitoring, .granted)
        await copy.center.applicationDidBecomeActive()

        #expect(copy.service.banner == RelaunchService.Banner(
            title: "Relaunch Cartouche to finish",
            message: "macOS applies Input Monitoring after a relaunch. Your game and settings stay as they are.",
            button: "Relaunch"))
        #expect(copy.remap.status == "Waiting for a relaunch")
        #expect(!copy.remap.isOn)
        #expect(copy.relauncher.count == 0, "Cartouche relaunched without being asked")
        snapshot(VStack {
            RelaunchBanner(service: copy.service, route: Self.controls)
            GatedOptionRow(option: copy.remap, title: "Remap keys for this game", subtitle: "Change what keys do in Hades")
        }.frame(width: 560), named: "relaunch-later-controls")

        let other = GatedOption(.notifications, flow: copy.flow)
        other.set(true)
        #expect(other.isOn)

        await copy.service.relaunch(to: Self.controls)
        #expect(copy.relauncher.count == 1)
    }

    @Test("Denied in macOS's prompt: no relaunch banner, the option says why instead")
    func deniedInstead() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .undetermined])
        let copy = await launch(tcc, scratch)
        copy.remap.set(true)
        await copy.flow.confirm()
        tcc.set(.inputMonitoring, .denied)
        await copy.center.applicationDidBecomeActive()

        #expect(copy.service.banner == nil)
        #expect(copy.remap.status == "Cartouche can't read the keyboard. Allow Input Monitoring in System Settings.")
    }

    @Test("Game running: Cartouche waits until the game quits, says so in the banner, then relaunches")
    func gameRunning() async throws {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .granted])
        let games = FakeGames(runningFor: 20)
        let copy = await launch(tcc, scratch, games: games)
        copy.service.markWaiting(.inputMonitoring)

        let relaunch = Task { await copy.service.relaunch(to: Self.controls) }
        await games.firstCall()
        #expect(await waitFor(10) { copy.service.phase == .waitingForGame },
                "the service never entered .waitingForGame")
        #expect(copy.service.banner?.title == "Cartouche relaunches when your game quits")
        #expect(copy.relauncher.count == 0, "relaunched while the game ran")
        snapshot(RelaunchBanner(service: copy.service, route: Self.controls).frame(width: 560),
                 named: "relaunch-game-running")

        await relaunch.value
        #expect(copy.relauncher.count == 1)
        #expect(copy.service.phase == .relaunching)
        #expect(copy.service.restore() == Self.controls)
    }

    @Test("A game any source knows — runner clone or console — holds the relaunch the same way")
    func consoleGameBlocks() async throws {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .granted])
        // The first source sees nothing; the second (a console game) reports running.
        // 100 checks at 5 ms keep it running well past waitFor's 50 ms poll.
        let games = CompositeGameActivity([FakeGames(), FakeGames(runningFor: 100)])
        let copy = await launch(tcc, scratch, games: FakeGames())
        let service = RelaunchService(defaults: scratch.defaults, center: copy.center, games: games,
                                      relauncher: copy.relauncher, pollInterval: .milliseconds(5))

        let relaunch = Task { await service.relaunch(to: Self.controls) }
        #expect(await waitFor(10) { service.phase == .waitingForGame },
                "a running console game did not hold the relaunch")
        #expect(copy.relauncher.count == 0, "relaunched while a console game ran")
        await relaunch.value
        #expect(copy.relauncher.count == 1)
    }

    @Test("A relauncher that cannot start puts the phase back to idle and clears the route")
    func relaunchFails() async {
        let scratch = ScratchDefaults()
        let games = FakeGames()
        let copy = await launch(FakeTCC(), scratch, games: games)
        copy.relauncher.succeeds = false

        await copy.service.relaunch(to: Self.controls)
        #expect(copy.relauncher.count == 1)
        #expect(copy.service.phase == .idle)
        #expect(copy.service.restore() == nil, "the saved screen was left for the next launch")

        // The service is not wedged: the next ask runs the relauncher again
        await copy.service.relaunch(to: Self.controls)
        #expect(copy.relauncher.count == 2)
    }

    @Test("A relaunch the user cancels is noticed once the helper's window ends")
    func cancelledQuitResets() async throws {
        let scratch = ScratchDefaults()
        let copy = await launch(FakeTCC(), scratch, games: FakeGames())
        let service = RelaunchService(defaults: scratch.defaults, games: FakeGames(),
                                    relauncher: copy.relauncher,
                                    pollInterval: .milliseconds(5), giveUpAfter: .milliseconds(100))

        await service.relaunch(to: Self.controls)
        #expect(service.phase == .relaunching)
        #expect(await waitFor(10) { service.phase == .idle },
                ".relaunching never reset after the give-up window")
        #expect(service.restore() == nil)
    }

    @Test("Cancel while waiting for the game: no relaunch, and no screen left to restore")
    func cancelWhileWaiting() async throws {
        let scratch = ScratchDefaults()
        let games = FakeGames(runningFor: 10_000)
        let copy = await launch(FakeTCC(), scratch, games: games)
        let relaunch = Task { await copy.service.relaunch(to: Self.controls) }
        await games.firstCall()
        #expect(await waitFor(10) { copy.service.phase == .waitingForGame })
        copy.service.cancel()
        await relaunch.value
        #expect(copy.relauncher.count == 0)
        #expect(copy.service.phase == .idle)
        #expect(copy.service.restore() == nil)
    }

    @Test("A screen saved long ago is not restored")
    func staleRoute() {
        let scratch = ScratchDefaults()
        let service = RelaunchService(defaults: scratch.defaults, games: FakeGames(), relauncher: FakeRelauncher())
        service.now = { Date(timeIntervalSince1970: 1_000) }
        service.save(Self.controls)
        service.now = { Date(timeIntervalSince1970: 1_000 + RelaunchService.maxAge + 1) }
        #expect(service.restore() == nil)
    }

    @Test("The reopen helper waits for the old process to end, then runs its command within 5 seconds")
    func reopenHelper() async throws {
        let work = try scratchDirectory("reopen")
        defer { try? FileManager.default.removeItem(at: work) }
        let marker = work.appending(path: "reopened")
        let old = Process()
        old.executableURL = URL(filePath: "/bin/sleep")
        old.arguments = ["30"]
        try old.run()

        let helper = try LiveRelauncher.reopen(after: old.processIdentifier,
                                               run: ["/usr/bin/touch", marker.path(percentEncoded: false)])
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "ran before the old process ended")

        old.terminate()
        old.waitUntilExit()
        let ended = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now - ended < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(ContinuousClock.now - ended < .seconds(5))
        helper.waitUntilExit()
    }

    @Test("The banners render in light and dark")
    func bannerRenders() async {
        let scratch = ScratchDefaults()
        let copy = await launch(FakeTCC([.inputMonitoring: .granted]), scratch)
        copy.service.markWaiting(.inputMonitoring)
        for dark in [false, true] {
            snapshot(RelaunchBanner(service: copy.service, route: Self.controls).frame(width: 560),
                     named: "relaunch-later", dark: dark)
            snapshot(GatedOptionRow(option: {
                let option = GatedOption(.inputMonitoring, flow: copy.flow)
                option.onWaitingForRelaunch = { _ in }
                return option
            }(), title: "Remap keys for this game", subtitle: "Change what keys do in Hades").frame(width: 560),
                     named: "remap-off", dark: dark)
        }
    }
}
