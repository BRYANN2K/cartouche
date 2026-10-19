import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import NotProtonApp

final class FakeGames: GameActivity, Sendable {
    private let running = Mutex(0)

    // The game quits after this many checks
    init(runningFor checks: Int = 0) {
        running.withLock { $0 = checks }
    }

    func isGameRunning() async -> Bool {
        running.withLock {
            guard $0 > 0 else { return false }
            $0 -= 1
            return true
        }
    }
}

@MainActor
final class FakeRelauncher: Relauncher {
    var count = 0
    func relaunch() { count += 1 }
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
        for _ in 0..<200 where copy.service.phase != .waitingForGame {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(copy.service.phase == .waitingForGame)
        #expect(copy.service.banner?.title == "Cartouche relaunches when your game quits")
        #expect(copy.relauncher.count == 0, "relaunched while the game ran")
        snapshot(RelaunchBanner(service: copy.service, route: Self.controls).frame(width: 560),
                 named: "relaunch-game-running")

        await relaunch.value
        #expect(copy.relauncher.count == 1)
        #expect(copy.service.phase == .relaunching)
        #expect(copy.service.restore() == Self.controls)
    }

    @Test("Cancel while waiting for the game: no relaunch, and no screen left to restore")
    func cancelWhileWaiting() async throws {
        let scratch = ScratchDefaults()
        let copy = await launch(FakeTCC(), scratch, games: FakeGames(runningFor: 10_000))
        let relaunch = Task { await copy.service.relaunch(to: Self.controls) }
        for _ in 0..<200 where copy.service.phase != .waitingForGame {
            try await Task.sleep(for: .milliseconds(1))
        }
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
        old.arguments = ["0.5"]
        try old.run()

        let helper = try LiveRelauncher.reopen(after: old.processIdentifier,
                                               run: ["/usr/bin/touch", marker.path(percentEncoded: false)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "ran before the old process ended")

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
