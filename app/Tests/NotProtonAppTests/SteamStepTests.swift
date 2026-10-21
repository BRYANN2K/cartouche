import Foundation
import Testing

@testable import NotProtonApp

// The install is a real write into a fixture Steam.app whose Contents folder is
// read-only, which macOS reports the same way as an App Management refusal.
@Suite("Steam step")
@MainActor
final class SteamStepTests {

    let work: URL
    let contents: URL
    let scratch = ScratchDefaults()
    var blocked = true
    var routes: [ScreenRoute] = []
    var opened: [String] = []

    init() throws {
        work = try scratchDirectory("steam-step")
        contents = work.appending(path: "Steam.app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appending(path: "Info.plist"))
        chmod(contents.appending(path: "MacOS").path(percentEncoded: false), 0o555)
    }

    deinit {
        chmod(contents.appending(path: "MacOS").path(percentEncoded: false), 0o755)
        try? FileManager.default.removeItem(at: work)
    }

    func makeStep(_ tcc: FakeTCC = FakeTCC()) -> SteamStep {
        let center = PermissionCenter(
            probe: tcc, requester: tcc, ledger: scratch.ledger,
            opener: { [unowned self] in opened.append($0.absoluteString); return true },
            notifications: NotificationCenter())
        let target = contents.appending(path: "MacOS/cartouche.dylib")
        return SteamStep(
            flow: PermissionFlow(center: center),
            install: { [unowned self] in
                if !blocked { chmod(contents.appending(path: "MacOS").path(percentEncoded: false), 0o755) }
                try WriteRefused.catching(target) { try Data("x".utf8).write(to: target) }
            },
            relaunch: { [unowned self] in routes.append($0) })
    }

    @Test("The fixture refusal is read as App Management by NotProton's detection")
    func fixtureIsAppManagement() {
        let target = contents.appending(path: "MacOS/cartouche.dylib")
        #expect(throws: WriteRefused.self) {
            try WriteRefused.catching(target) { try Data("x".utf8).write(to: target) }
        }
        #expect(Remedy(forPath: target.path(percentEncoded: false)) == .appManagement)
    }

    @Test("Denied: the Steam step shows the reason and Open System Settings, and onboarding can go on")
    func deniedDuringOnboarding() async {
        let step = makeStep()
        step.setUp()
        #expect(step.flow.asking?.permission == .appManagement, "Cartouche's explanation came first")
        await step.flow.confirm()

        #expect(step.phase == .blocked(.appManagement))
        #expect(step.detail == "macOS blocked the change. Allow Cartouche in App Management, then try again.")
        #expect(step.canContinue)
        #expect(step.flow.center.state(.appManagement) == .denied)

        step.openSettings()
        #expect(opened.first == "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
    }

    @Test("Allowed after the refusal: Try Again finishes the step")
    func allowedThenTryAgain() async {
        let step = makeStep()
        step.setUp()
        await step.flow.confirm()
        blocked = false

        await step.tryAgain()

        #expect(step.phase == .done)
        #expect(step.flow.center.state(.appManagement) == .allowed)
        #expect(FileManager.default.fileExists(atPath: contents.appending(path: "MacOS/cartouche.dylib").path))
    }

    @Test("Allowed but still refused: the step offers Relaunch Cartouche, which reopens on Stores")
    func notYetApplied() async {
        let tcc = FakeTCC([.appManagement: .granted])
        let step = makeStep(tcc)
        step.setUp()
        await step.flow.confirm()
        step.openSettings()
        // Back from System Settings: the write check now passes
        await step.flow.center.applicationDidBecomeActive()
        #expect(step.flow.center.state(.appManagement) == .allowed)

        await step.tryAgain()

        #expect(step.phase == .notApplied)
        #expect(step.detail.contains("relaunch Cartouche to finish"))
        step.relaunchCartouche()
        #expect(routes == [ScreenRoute(screen: "onboarding", detail: "stores")])
    }

    @Test("A failure that is not a write refusal shows its message, and onboarding can go on")
    func otherProblems() async {
        let step = makeStep()
        let failing = SteamStep(
            flow: step.flow,
            install: { throw StepFailure(step: "Install", detail: "Steam is running.") },
            relaunch: { _ in })
        await failing.tryAgain()
        #expect(failing.phase == .failed(StepFailure(step: "Install", detail: "Steam is running.").localizedDescription))
        #expect(failing.canContinue)
    }

    @Test("The Steam step row renders each phase")
    func rowRenders() async {
        let step = makeStep()
        snapshot(SteamStepRow(step: step).frame(width: 560), named: "steam-step-idle")
        step.setUp()
        await step.flow.confirm()
        for dark in [false, true] {
            snapshot(SteamStepRow(step: step).frame(width: 560), named: "steam-step-blocked", dark: dark)
        }
    }
}
