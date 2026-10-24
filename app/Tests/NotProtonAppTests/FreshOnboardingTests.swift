import Foundation
import Synchronization
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Fresh onboarding Steam handoff")
@MainActor
struct FreshOnboardingTests {
    @Test("Steam waits for runner preparation, opens automatically once, and finishing does not restart it again")
    func automaticSteam() async throws {
        let scene = try OnboardingScene("automatic-steam")
        defer { scene.remove() }
        let prepared = Mutex(false), starts = Mutex(0)
        let tasks = SetupTasks(installRunner: { _ in
            try await Task.sleep(for: .milliseconds(100))
            prepared.withLock { $0 = true }
        })
        let model = try scene.model(steamBlocked: false, setup: tasks)
        model.steam = SteamControl(isRunning: { false }, restart: {
            #expect(prepared.withLock { $0 })
            starts.withLock { $0 += 1 }
            return true
        })
        tasks.startRunner(OnboardingScene.wine, alreadyInstalled: false)
        let install = Task { await model.steamStep.tryAgain() }
        await Task.yield()
        #expect(scene.counts.steamInstalls == 0)
        await install.value
        // steamRestarted is set after restart returns, so wait for both
        for _ in 0..<200 where starts.withLock({ $0 }) == 0 || model.steamRestarted != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scene.counts.steamInstalls == 1)
        #expect(starts.withLock { $0 } == 1)
        #expect(model.steamRestarted == true)
        model.finish()
        await Task.yield()
        #expect(starts.withLock { $0 } == 1)
    }

    @Test("A failed runner setup cannot claim Steam setup succeeded or start Steam")
    func failedPreparation() async throws {
        let scene = try OnboardingScene("failed-steam-preparation")
        defer { scene.remove() }
        let starts = Mutex(0)
        let tasks = SetupTasks(installRunner: { _ in
            throw StepFailure(step: "Runner", detail: "Preparation failed")
        })
        let model = try scene.model(steamBlocked: false, setup: tasks)
        model.steam = SteamControl(isRunning: { false }, restart: { starts.withLock { $0 += 1 }; return true })
        tasks.startRunner(OnboardingScene.wine, alreadyInstalled: false)
        await model.steamStep.tryAgain()
        #expect(scene.counts.steamInstalls == 0)
        #expect(starts.withLock { $0 } == 0)
        if case .failed(let message) = model.steamStep.phase {
            #expect(message.contains("Preparation failed"))
        } else {
            Issue.record("Steam setup unexpectedly succeeded after runner failure")
        }
    }
    @Test("Never signed in: Set Up opens Steam, waits for the sign-in, then installs and reopens Steam")
    func signInFirst() async throws {
        let scene = try OnboardingScene("steam-sign-in")
        defer { scene.remove() }
        let signedIn = Mutex(false), opens = Mutex(0), starts = Mutex(0)
        let model = try scene.model(steamBlocked: false, setup: SetupTasks())
        model.steam = SteamControl(
            isRunning: { false },
            restart: { starts.withLock { $0 += 1 }; return true },
            signedIn: { signedIn.withLock { $0 } },
            open: { opens.withLock { $0 += 1 }; return true })
        let install = Task { await model.steamStep.tryAgain() }
        for _ in 0..<200 where !model.steamStep.waitingForSteam {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.steamStep.waitingForSteam)
        #expect(model.steamStep.detail == "Sign in to Steam. Setup goes on once you are signed in.")
        #expect(model.steamStep.canContinue)
        #expect(opens.withLock { $0 } == 1)
        #expect(scene.counts.steamInstalls == 0)
        signedIn.withLock { $0 = true }
        await install.value
        for _ in 0..<200 where starts.withLock({ $0 }) == 0 || model.steamRestarted != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.steamStep.waitingForSteam)
        #expect(scene.counts.steamInstalls == 1)
        #expect(starts.withLock { $0 } == 1)
    }

    @Test("Controller choices render within their card")
    func controllerPresentation() async throws {
        let scene = try OnboardingScene("controller-card")
        defer { scene.remove() }
        var state = OnboardingState()
        state.step = .controller
        scene.store.save(state)
        scene.findings.controllers = []
        let model = try scene.model()
        await model.prepare()
        for dark in [false, true] {
            await sheetSnapshot(OnboardingControllerOptions(model: model)
                .environment(\.glassMode, .classic).padding(16), named: "controller-options",
                size: CGSize(width: 612, height: 330), dark: dark)
        }
    }

}
