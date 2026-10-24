import Foundation
import Testing

@testable import NotProtonApp

@Suite("Permission request flow")
@MainActor
struct PermissionFlowTests {

    @Test("The macOS prompt comes only after Continue in Cartouche's sheet")
    func promptAfterSheet() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.downloads: .unreadable])
        tcc.decide(.downloads, .granted)
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.downloads) { outcomes.append($0) }
        #expect(flow.asking?.permission == .downloads, "no sheet was shown")
        #expect(tcc.requests.isEmpty, "macOS was asked while the sheet was up")

        await flow.confirm()
        #expect(tcc.requests == [.downloads])
        #expect(flow.asking == nil)
        #expect(outcomes == [.allowed])
    }

    @Test("Not Now closes the sheet and macOS is never asked")
    func notNow() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC()
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.notifications) { outcomes.append($0) }
        flow.notNow()
        await flow.confirm()

        #expect(tcc.requests.isEmpty)
        #expect(outcomes == [.notNow])
        #expect(!scratch.ledger.wasAsked(.notifications))
    }

    @Test("An allowed permission needs no sheet and no prompt")
    func alreadyAllowed() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .granted])
        let center = makeCenter(tcc, scratch)
        await center.refresh()
        let flow = PermissionFlow(center: center)
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.inputMonitoring) { outcomes.append($0) }

        #expect(flow.asking == nil)
        #expect(tcc.requests.isEmpty)
        #expect(outcomes == [.allowed])
    }

    @Test("A denied permission goes straight to the feature's fix, since macOS will not ask again")
    func alreadyDenied() async {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.denied, for: .downloads)
        let tcc = FakeTCC()
        let center = makeCenter(tcc, scratch)
        await center.refresh()
        let flow = PermissionFlow(center: center)
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.downloads) { outcomes.append($0) }

        #expect(flow.asking == nil)
        #expect(tcc.requests.isEmpty)
        #expect(outcomes == [.denied])
    }

    @Test("The screen is saved right before the prompt, not when the sheet opens")
    func beforePromptHook() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC([.inputMonitoring: .undetermined])
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        var events: [String] = []
        flow.beforePrompt = { events.append("save \($0.rawValue), requests \(tcc.requests.count)") }

        flow.start(.inputMonitoring) { events.append("done \($0)") }
        #expect(events.isEmpty)
        await flow.confirm()

        #expect(events == ["save inputMonitoring, requests 0", "done pending"])
    }

    @Test("Only Input Monitoring's explanation says a relaunch is needed, and every reason is one sentence")
    func explanations() {
        for permission in Permission.allCases {
            guard let explanation = permission.explanation else {
                #expect([.steamInput, .gameInputMonitoring, .keychain].contains(permission))
                continue
            }
            #expect((explanation.relaunch != nil) == permission.needsRelaunch, "\(permission)")
            let sentences = explanation.reason.split(separator: ". ").count
            #expect(sentences == 1 && explanation.reason.hasSuffix("."), "\(permission): \(explanation.reason)")
        }
    }

    @Test("App Management's Continue runs the feature's own write instead of a prompt")
    func attemptReplacesPrompt() async {
        let scratch = ScratchDefaults()
        let tcc = FakeTCC()
        let flow = PermissionFlow(center: makeCenter(tcc, scratch))
        var attempts = 0
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.appManagement, context: .onboarding, attempt: {
            attempts += 1
            return .denied
        }) { outcomes.append($0) }
        #expect(attempts == 0)
        await flow.confirm()

        #expect(attempts == 1)
        #expect(tcc.requests.isEmpty)
        #expect(outcomes == [.denied])
    }

    @Test("App Management already allowed: the write runs with no sheet")
    func allowedAttemptSkipsSheet() async throws {
        let scratch = ScratchDefaults()
        scratch.ledger.note(.allowed, for: .appManagement)
        let tcc = FakeTCC()
        let center = makeCenter(tcc, scratch)
        await center.refresh()
        let flow = PermissionFlow(center: center)
        var outcomes: [PermissionFlow.Outcome] = []

        flow.start(.appManagement, context: .onboarding, attempt: { .allowed }) { outcomes.append($0) }
        #expect(flow.asking == nil)
        for _ in 0..<100 where outcomes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(outcomes == [.allowed])
        #expect(tcc.requests.isEmpty)
    }

    @Test("Starting a second request closes the first as Not Now")
    func secondStart() {
        let scratch = ScratchDefaults()
        let flow = PermissionFlow(center: makeCenter(FakeTCC(), scratch))
        var outcomes: [String] = []
        flow.start(.notifications) { outcomes.append("notifications \($0)") }
        flow.start(.downloads) { outcomes.append("downloads \($0)") }
        #expect(outcomes == ["notifications notNow"])
        #expect(flow.asking?.permission == .downloads)
    }

    @Test("The explanation sheet renders in light and dark")
    func sheetRenders() throws {
        for permission in [Permission.inputMonitoring, .downloads, .appManagement, .notifications] {
            let explanation = try #require(permission.explanation)
            for dark in [false, true] {
                let size = snapshot(
                    PermissionExplanationView(explanation: explanation, onNotNow: {}, onContinue: {}),
                    named: "explain-\(permission.rawValue)", dark: dark)
                #expect(size.width > 300 && size.height > 80)
            }
        }
    }
}
