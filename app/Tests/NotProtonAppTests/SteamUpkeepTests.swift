import Foundation
import Testing

@testable import NotProtonApp

private func upkeepSnapshot(
    steam: SteamDeployment = .installed(version: "1"),
    content: DeploymentContent.Status = .mismatchedDylib(["cartouche.dylib"]),
    running: Bool = false,
    recorded: Bool = true
) -> StatusSnapshot {
    StatusSnapshot(
        steam: steam, steamRunning: running, updateBlocked: false,
        crossOver: [], runner: .ready(builds: ["fixture"]),
        payload: PayloadState(expected: 0, present: 0, missing: [],
            overlayShimPresent: true, iconmakerPresent: true, appinfoPresent: true,
            signatureDatabase: "1.json", legacyCompatPresent: 0,
            legacyCompatExpected: 0, manifestProblem: nil),
        installContent: content,
        buildRecorded: recorded
    )
}

// An existing installation never authorizes an automatic integration update.
@Suite("Steam integration upkeep")
struct SteamUpkeepDecisionTests {

    @Test("Changed integration files require a manual action even with Steam closed")
    func installNow() {
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false, snapshot: upkeepSnapshot()) == .manual)
        for content: DeploymentContent.Status in [.update(["run"]), .repair(["run"]), .unrecorded(["run"])] {
            #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false,
                                       snapshot: upkeepSnapshot(content: content)) == .manual)
        }
        // Steam replaced its own bundle and dropped the insert: the dylib is missing
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false,
                                   snapshot: upkeepSnapshot(steam: .notInstalled, content: .repair(["cartouche.dylib"]))) == .manual)
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false,
                                   snapshot: upkeepSnapshot(steam: .outdated(deployed: "0", bundled: "1"), content: .unchecked)) == .manual)
    }

    @Test("Steam running: keep the update manual")
    func waitForQuit() {
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false,
                                   snapshot: upkeepSnapshot(running: true)) == .manual)
    }

    @Test("Never set up: nothing, whatever Steam holds")
    func neverWithoutConsent() {
        for running in [false, true] {
            for content: DeploymentContent.Status in [.mismatchedDylib(["d"]), .update(["d"]), .repair(["d"]), .current] {
                #expect(SteamUpkeep.decide(setUpBefore: false, failedBefore: false,
                                           snapshot: upkeepSnapshot(content: content, running: running)) == .nothing)
            }
        }
        #expect(SteamUpkeep.decide(setUpBefore: false, failedBefore: false,
                                   snapshot: upkeepSnapshot(steam: .notInstalled, content: .unchecked)) == .nothing)
    }

    @Test("Current files, another tool's Steam or a blocked install: nothing")
    func nothingToDo() {
        let cases: [(SteamDeployment, DeploymentContent.Status)] = [
            (.installed(version: "1"), .current),
            (.installed(version: "1"), .newerInstalled),
            (.installed(version: "1"), .unavailable("fixture")),
            (.steamMissing, .unchecked),
            (.foreign(insert: "fixture"), .unchecked),
            (.notProton(insert: "fixture"), .unchecked),
            (.notInstalled, .newerInstalled),
        ]
        for (steam, content) in cases {
            #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: false,
                                       snapshot: upkeepSnapshot(steam: steam, content: content)) == .nothing,
                    "\(steam) \(content)")
        }
    }

    @Test("A previous failure does not authorize an automatic retry")
    func manualAfterFailure() {
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: true, snapshot: upkeepSnapshot()) == .manual)
        #expect(SteamUpkeep.decide(setUpBefore: true, failedBefore: true,
                                   snapshot: upkeepSnapshot(content: .current)) == .nothing)
    }

    @Test("Set up is the recorded choice, or an earlier install's build record while Steam still names Cartouche")
    func setUpBefore() {
        let scratch = ScratchDefaults()
        #expect(SteamUpkeep.wasSetUp(upkeepSnapshot(), defaults: scratch.defaults))
        #expect(!SteamUpkeep.wasSetUp(upkeepSnapshot(recorded: false), defaults: scratch.defaults))
        #expect(!SteamUpkeep.wasSetUp(upkeepSnapshot(steam: .notInstalled), defaults: scratch.defaults))
        #expect(!SteamUpkeep.wasSetUp(upkeepSnapshot(steam: .foreign(insert: "x")), defaults: scratch.defaults))

        scratch.defaults.set(false, forKey: SteamUpkeep.setUpKey)
        #expect(!SteamUpkeep.wasSetUp(upkeepSnapshot(), defaults: scratch.defaults))
        scratch.defaults.set(true, forKey: SteamUpkeep.setUpKey)
        #expect(SteamUpkeep.wasSetUp(upkeepSnapshot(steam: .notInstalled, recorded: false), defaults: scratch.defaults))
    }
}

@MainActor
@Suite("Steam integration upkeep runs")
final class SteamUpkeepRunTests {

    let scratch = ScratchDefaults()
    var installs: [Bool] = []
    var reloads = 0
    var next = upkeepSnapshot()

    // No real refresh or install: the snapshot is the fixture's, the install records its call
    func makeStatus(failing failure: String? = nil, after: StatusSnapshot = upkeepSnapshot(content: .current)) -> SystemStatus {
        let status = SystemStatus()
        status.upkeepDefaults = scratch.defaults
        status.refreshAfterRun = { _ in }
        status.refreshStatus = { [unowned self] in $0.snapshot = next }
        status.upkeepInstall = { [unowned self] status, repairing in
            installs.append(repairing)
            if let failure { status.setFailure(failure) } else { status.snapshot = after }
        }
        status.onUpkeepInstalled = { [unowned self] in reloads += 1 }
        return status
    }

    @Test("Status checks and Steam exit never install or repair integration files", arguments: [false, true])
    func manualUpdatesOnly(running: Bool) async {
        scratch.defaults.set(true, forKey: SteamUpkeep.setUpKey)
        next = upkeepSnapshot(running: running)
        let status = makeStatus(failing: "This closure must never run.")
        await status.keepSteamIntegrationCurrent()
        #expect(installs.isEmpty)
        #expect(reloads == 0)
        #expect(status.upkeep == .idle)
        #expect(!status.updatesItself)
        #expect(status.failure == nil)
        #expect(SteamIntegrationIssue.current(in: next, upkeep: status.upkeep) == .repair)
        let line = SteamIntegrationLine.make(next, canInstall: true, upkeep: status.upkeep)
        #expect(line.action == .repair)
        #expect(line.label == (running ? "Quit Steam and Repair" : "Repair"))

        next = upkeepSnapshot(running: false)
        await status.keepSteamIntegrationCurrent()
        #expect(installs.isEmpty)
        #expect(reloads == 0)
    }

    @Test("A first installation also requires the user's action")
    func neverInstallsWithoutConsent() async {
        scratch.defaults.set(false, forKey: SteamUpkeep.setUpKey)
        next = upkeepSnapshot(steam: .notInstalled, content: .unchecked, recorded: false)
        let status = makeStatus()
        await status.keepSteamIntegrationCurrent()
        #expect(installs.isEmpty)
        #expect(SteamIntegrationLine.make(next, canInstall: true).action == .install)
    }

    @Test("Read-only integration checks never quit Steam")
    func leavesSteamRunning() async throws {
        // Steam is not running in the test host, so the stopper only reports that nothing was stopped
        let stopped = try await offMain {
            guard !SteamBundle.isRunning else { return nil as Bool? }
            return try SystemStatus.leaveSteamRunning(URL(filePath: "/nonexistent/Steam.app"), {})
        }
        if let stopped {
            #expect(stopped == false)
        }
    }
}

@MainActor
@Suite("Steam library refresh")
struct SteamLibraryRefreshTests {

    @Test("An export written between the first load and the watcher's start still shows")
    func exportBeforeWatch() async throws {
        let fixture = try SteamFixture("watch-baseline")
        defer { fixture.remove() }
        let model = libraryModel(fixture, running: true, defaults: ScratchDefaults())
        await model.load()
        #expect(model.steam.games.count == 6)
        try fixture.writeExport()
        model.watch(every: .milliseconds(50))
        #expect(await waitFor { model.steam.games.count == 8 })
    }

    @Test("Steam quitting tells the upkeep")
    func steamQuitHook() async throws {
        let fixture = try SteamFixture("watch-quit")
        defer { fixture.remove() }
        let running = Box(true)
        var importer = fixture.importer(installed: true, running: true)
        importer.isRunning = { running.value }
        let model = LibraryModel(store: LibraryStore(folder: fixture.support), importer: importer,
                                 defaults: ScratchDefaults().defaults)
        let quits = Box(0)
        model.onSteamQuit = { quits.value += 1 }
        await model.load()
        var stamp = model.importer.exportStamp()
        var wasRunning = true
        running.value = false
        await model.watchTick(tick: 5, stamp: &stamp, running: &wasRunning)
        #expect(await waitFor { quits.value == 1 })
        #expect(model.steam.presence == .closed)
    }
}
