import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner model")
struct RunnerModelTests {

    private static let ntdll = "x86_64-windows/ntdll.dll is not the patched copy"

    private func runner(_ state: Runner.State, build: RunnerBuild? = SupportedRunners.all[0], installed: Bool = true) -> Runner {
        Runner(
            id: build?.id ?? "/Applications/CrossOver.app", kind: .crossOver,
            version: build?.bundleVersion ?? "30.0", displayVersion: build?.displayVersion ?? "30.0",
            flavors: build.map { Runner.flavors(of: $0) } ?? [], state: state, build: build,
            source: nil, isInstalled: installed
        )
    }

    @Test("A found runner installs, then is ready once every pin matches")
    func installsToReady() {
        var runner = runner(.available, installed: false)
        let applied = runner.apply(.install)
        #expect(applied)
        #expect(runner.state == .installing(from: .available))
        let applied2 = runner.apply(.verified(problems: []))
        #expect(applied2)
        #expect(runner.state == .ready)
        #expect(runner.reason == nil)
    }

    @Test("An install that leaves a file off its pin ends damaged, naming the file")
    func installsToDamaged() {
        var runner = runner(.available)
        runner.apply(.install)
        runner.apply(.verified(problems: [Self.ntdll]))
        #expect(runner.state == .damaged(files: [Self.ntdll]))
        #expect(runner.reason == Self.ntdll)
    }

    @Test("A failed install falls back to the state it started from")
    func failureRestores() {
        for start in [Runner.State.available, .ready, .damaged(files: [Self.ntdll])] {
            var runner = runner(start)
            runner.apply(.install)
            let applied = runner.apply(.failed)
            #expect(applied)
            #expect(runner.state == start)
        }
    }

    @Test("A refresh moves a ready runner to damaged and a repaired one back to ready")
    func refreshFollowsPins() {
        var runner = runner(.ready)
        let applied = runner.apply(.verified(problems: [Self.ntdll]))
        #expect(applied)
        #expect(runner.state == .damaged(files: [Self.ntdll]))

        let applied2 = runner.apply(.install)
        #expect(applied2)
        #expect(runner.state == .installing(from: .damaged(files: [Self.ntdll])))
        runner.apply(.verified(problems: []))
        #expect(runner.state == .ready)
    }

    @Test("An unsupported runner refuses every event and keeps its reason")
    func unsupportedIsTerminal() {
        let reason = "Version 30.0 not supported"
        var runner = runner(.unsupported(reason: reason), build: nil, installed: false)
        for event in [Runner.Event.install, .verified(problems: []), .failed] {
            let applied = runner.apply(event)
            #expect(!applied)
        }
        #expect(runner.state == .unsupported(reason: reason))
        #expect(runner.reason == reason)
        #expect(!runner.state.canInstall)
        #expect(!runner.isOffered)
    }

    @Test("A runner already installing cannot start a second install")
    func noOverlappingInstall() {
        var runner = runner(.ready)
        runner.apply(.install)
        #expect(!runner.state.canInstall)
        let applied = runner.apply(.install)
        #expect(!applied)
    }

    @Test("Events that do not apply leave the state alone")
    func strayEvents() {
        var found = runner(.available, installed: false)
        let applied = found.apply(.verified(problems: []))
        #expect(!applied)
        let applied2 = found.apply(.failed)
        #expect(!applied2)
        #expect(found.state == .available)

        var ready = runner(.ready)
        let applied3 = ready.apply(.failed)
        #expect(!applied3)
        #expect(ready.state == .ready)
    }

    @Test("Only a pinned build with a complete copy is offered")
    func offered() {
        #expect(runner(.ready).isOffered)
        #expect(runner(.damaged(files: [Self.ntdll])).isOffered)
        #expect(!runner(.available, installed: false).isOffered)
        #expect(!runner(.damaged(files: ["lib/wine"]), installed: false).isOffered)
    }

    @Test("Flavors follow the build's tools, with FEX only where it runs")
    func flavors() {
        let fex = SupportedRunners.build(id: "27.0.0.40921-fex")!
        let x86 = SupportedRunners.build(id: "27.0.0.40921")!
        #expect(Runner.flavors(of: fex, fexAvailable: true) == [.rosetta, .fex])
        #expect(Runner.flavors(of: fex, fexAvailable: false) == [.rosetta])
        #expect(Runner.flavors(of: x86, fexAvailable: true) == [.rosetta])
    }

    @Test("Kinds carry their product names")
    func kinds() {
        #expect(Runner.Kind.allCases.map(\.name) == ["CrossOver", "Wine", "Game Porting Toolkit"])
    }
}
