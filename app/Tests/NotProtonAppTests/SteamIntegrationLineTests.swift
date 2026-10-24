import Foundation
import Testing

@testable import NotProtonApp

// Settings > Steam shows one Cartouche line: one plain message and at most one action.
@Suite("Steam integration line")
struct SteamIntegrationLineTests {
    private func snapshot(
        steam: SteamDeployment = .installed(version: "1"),
        content: DeploymentContent.Status = .current,
        running: Bool = false
    ) -> StatusSnapshot {
        StatusSnapshot(
            steam: steam, steamRunning: running, updateBlocked: false,
            crossOver: [], runner: .ready(builds: ["fixture"]),
            payload: PayloadState(expected: 0, present: 0, missing: [],
                overlayShimPresent: true, iconmakerPresent: true, appinfoPresent: true,
                signatureDatabase: "1.json", legacyCompatPresent: 0,
                legacyCompatExpected: 0, manifestProblem: nil),
            installContent: content
        )
    }

    @Test("A dylib that is not the recorded one reads as a plain repair, with Repair as the action")
    func mismatchedDylib() {
        let line = SteamIntegrationLine.make(snapshot(content: .mismatchedDylib(["cartouche.dylib"])), canInstall: true)
        #expect(line.value == "Cartouche in Steam needs a repair.")
        #expect(line.tone == .warning)
        #expect(line.action == .repair)
        #expect(line.label == "Repair")
        #expect(line.isEnabled)
        #expect(!line.quitsSteam)
        #expect(line.files == ["cartouche.dylib"])
        #expect(!(line.detail ?? "").contains("build record"))
    }

    @Test("While Steam runs the action quits Steam first, and a busy status disables it")
    func steamRunning() {
        var line = SteamIntegrationLine.make(
            snapshot(content: .mismatchedDylib(["cartouche.dylib"]), running: true), canInstall: true)
        #expect(line.quitsSteam)
        #expect(line.label == "Quit Steam and Repair")
        #expect(line.isEnabled)
        line = SteamIntegrationLine.make(snapshot(content: .update(["run"]), running: true), canInstall: true)
        #expect(line.label == "Quit Steam and Update")
        line = SteamIntegrationLine.make(snapshot(steam: .notInstalled, content: .unchecked, running: true), canInstall: true)
        #expect(line.label == "Quit Steam and Install")
        line = SteamIntegrationLine.make(snapshot(content: .repair(["run"])), canInstall: false)
        #expect(line.action == .repair)
        #expect(!line.isEnabled)
    }

    @Test("Each state picks its one action")
    func actions() {
        let cases: [(SteamDeployment, DeploymentContent.Status, SteamIntegrationLine.Action?)] = [
            (.steamMissing, .unchecked, nil),
            (.notInstalled, .unchecked, .install),
            (.notInstalled, .newerInstalled, nil),
            (.installed(version: "1"), .current, nil),
            (.installed(version: "1"), .unavailable("fixture"), nil),
            (.installed(version: "1"), .update(["run"]), .update),
            (.installed(version: "1"), .unrecorded(["run"]), .update),
            (.installed(version: "1"), .repair(["run"]), .repair),
            (.outdated(deployed: "0", bundled: "1"), .unchecked, .update),
            (.foreign(insert: "fixture"), .unchecked, nil),
            (.notProton(insert: "fixture"), .unchecked, .replaceNotProton),
        ]
        for (steam, content, action) in cases {
            let line = SteamIntegrationLine.make(snapshot(steam: steam, content: content), canInstall: true)
            #expect(line.action == action, "\(steam) \(content)")
            #expect(line.label == nil || action != nil)
        }
    }

    @Test("The takeover never asks to quit Steam first")
    func takeoverKeepsItsLabel() {
        let line = SteamIntegrationLine.make(snapshot(steam: .notProton(insert: "fixture"), running: true), canInstall: true)
        #expect(!line.quitsSteam)
        #expect(line.label == "Replace NotProton")
    }

    @Test("A healthy install shows its version and no action")
    func installed() {
        let line = SteamIntegrationLine.make(snapshot(steam: .installed(version: "0.1.0")), canInstall: true)
        #expect(line.value == "Installed (0.1.0)")
        #expect(line.tone == .ok)
        #expect(line.action == nil)
        #expect(!line.isEnabled)
    }

    @MainActor
    @Test("Quit Steam and Repair asks first and runs nothing until confirmed")
    func quitAsksFirst() async {
        let status = SystemStatus()
        status.snapshot = snapshot(content: .mismatchedDylib(["cartouche.dylib"]), running: true)
        #expect(status.needsRepairInSteam)
        await status.request(.repair, quittingSteam: true)
        #expect(status.pendingConfirmation == .quitSteam)
        #expect(status.pendingSteamAction == .repair)
        #expect(status.activity == nil)
        status.cancelQuitSteam()
        #expect(status.pendingSteamAction == nil)
    }

    @MainActor
    @Test("Blocked content offers no repair and no quit question")
    func blockedContent() async {
        let status = SystemStatus()
        status.snapshot = snapshot(content: .newerInstalled, running: true)
        #expect(!status.needsRepairInSteam)
        await status.request(.repair, quittingSteam: true)
        #expect(status.pendingConfirmation == nil)
        #expect(status.pendingSteamAction == nil)
    }
}
