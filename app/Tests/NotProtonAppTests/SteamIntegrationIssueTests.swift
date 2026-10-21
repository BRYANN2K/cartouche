import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam integration issue")
struct SteamIntegrationIssueTests {
    private func snapshot() -> StatusSnapshot {
        StatusSnapshot(
            steam: .installed(version: "1"), steamRunning: false, updateBlocked: false,
            crossOver: [], runner: .ready(builds: ["fixture"]),
            payload: PayloadState(expected: 0, present: 0, missing: [],
                overlayShimPresent: true, iconmakerPresent: true, appinfoPresent: true,
                signatureDatabase: "1.json", legacyCompatPresent: 0,
                legacyCompatExpected: 0, manifestProblem: nil),
            installContent: .current
        )
    }

    @Test("No snapshot and healthy integration stay quiet")
    func quiet() {
        #expect(SteamIntegrationIssue.current(in: nil) == nil)
        #expect(SteamIntegrationIssue.current(in: snapshot()) == nil)
    }

    @Test("Steam deployment problems take priority")
    func deployment() {
        let cases: [(SteamDeployment, SteamIntegrationIssue)] = [
            (.steamMissing, .steamMissing), (.notInstalled, .notInstalled),
            (.foreign(insert: "fixture"), .otherIntegration),
            (.notProton(insert: "fixture"), .otherIntegration),
            (.outdated(deployed: "0", bundled: "1"), .update)
        ]
        for (deployment, issue) in cases {
            var state = snapshot()
            state.steam = deployment
            state.runner = .none
            #expect(SteamIntegrationIssue.current(in: state) == issue)
        }
    }

    @Test("Content blocks override update and repair suggestions")
    func content() {
        let cases: [(DeploymentContent.Status, SteamIntegrationIssue)] = [
            (.newerInstalled, .newerInstalled), (.unavailable("fixture"), .unavailable),
            (.update(["fixture"]), .update), (.repair(["fixture"]), .repair),
            (.unrecorded(["fixture"]), .repair)
        ]
        for (content, issue) in cases {
            var state = snapshot()
            state.steam = .outdated(deployed: "0", bundled: "1")
            state.installContent = content
            state.payload.signatureDatabase = nil
            #expect(SteamIntegrationIssue.current(in: state) == issue)
        }
    }

    @Test("Incomplete payload requires repair before tools setup")
    func payload() {
        var state = snapshot()
        state.runner = .none
        state.payload.overlayShimPresent = false
        #expect(SteamIntegrationIssue.current(in: state) == .repair)
        state.payload.overlayShimPresent = true
        state.payload.manifestProblem = "fixture"
        #expect(SteamIntegrationIssue.current(in: state) == .repair)
    }

    @Test("Available sources and unsupported runners are not installed tools")
    func missingTools() {
        var state = snapshot()
        state.runner = .none
        state.runners = [runner(state: .available, installed: false),
                         runner(state: .unsupported(reason: "fixture"), installed: false)]
        #expect(SteamIntegrationIssue.current(in: state) == .missingTools)
        state.runners = [runner(state: .ready, installed: true)]
        #expect(SteamIntegrationIssue.current(in: state) == nil)
        state.runners = [runner(state: .ready, installed: false)]
        #expect(SteamIntegrationIssue.current(in: state) == .missingTools)
    }

    @Test("Installed builds count even without the unified runner list")
    func installedBuilds() {
        var state = snapshot()
        state.runner = .none
        state.installedRunners = Array(SupportedRunners.all.prefix(1))
        #expect(!state.installedRunners.isEmpty)
        #expect(SteamIntegrationIssue.current(in: state) == nil)
    }

    @Test("Damaged and unpatched tools offer repair, not a fresh setup")
    func damagedTools() {
        var state = snapshot()
        state.runner = .unpatched(builds: ["fixture"], problems: ["fixture"])
        #expect(SteamIntegrationIssue.current(in: state) == .damagedTools)
        state.runner = .none
        state.damagedRunners = ["fixture"]
        #expect(SteamIntegrationIssue.current(in: state) == .damagedTools)
        state.damagedRunners = []
        state.runners = [runner(state: .damaged(files: ["fixture"]), installed: false)]
        #expect(SteamIntegrationIssue.current(in: state) == .damagedTools)
    }

    private func runner(state: Runner.State, installed: Bool) -> Runner {
        Runner(id: "fixture", kind: .crossOver, version: "1", displayVersion: "1",
               flavors: [.rosetta], state: state, build: nil, source: nil,
               isInstalled: installed)
    }
}
