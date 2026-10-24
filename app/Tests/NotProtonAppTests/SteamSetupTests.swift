import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam not installed")
@MainActor
struct SteamSetupTests {

    struct Broke: LocalizedError { var errorDescription: String? { "disk full" } }

    private func setup(brew: String? = nil, download: @escaping @Sendable (URL) async throws -> Void = { _ in },
                       bundleID: String? = "com.valvesoftware.steam", defaults: ScratchDefaults) -> SteamSetup {
        var steps = SteamSetup.Steps()
        steps.downloadAndInstall = download
        steps.runBrew = { _ in }
        steps.brewPath = { brew }
        steps.bundleID = { _ in bundleID }
        steps.applications = URL(filePath: "/nonexistent-applications")
        return SteamSetup(steps: steps, defaults: defaults.defaults)
    }

    @Test("The Steam source shows Install Steam when Steam is missing, with a Get badge")
    func screen() async throws {
        let fixture = try SteamFixture("not-installed")
        defer { fixture.remove() }
        let model = libraryModel(fixture, installed: false, defaults: ScratchDefaults())
        await model.load()
        model.selection = .source(.steam)
        #expect(model.screen == .steamInstall)
        #expect(model.title == "Steam")
        #expect(model.subtitle == "Not installed")
        #expect(model.badge(.source(.steam)) == "Get")
    }

    @Test("Install with Homebrew is offered only when Homebrew is on this Mac")
    func homebrewOnlyWhenPresent() {
        let scratch = ScratchDefaults()
        #expect(setup(brew: nil, defaults: scratch).homebrew == nil)
        #expect(setup(brew: "/opt/homebrew/bin/brew", defaults: scratch).homebrew == "/opt/homebrew/bin/brew")
        #expect(SteamSetup.homebrewCommand == "brew install --cask steam")
        #expect(SteamSetup.valveInstaller.host == "cdn.fastly.steamstatic.com")
    }

    @Test("Download Steam gets Valve's installer, then asks to sign in once in Steam")
    func download() async {
        let scratch = ScratchDefaults()
        let target = Box<URL?>(nil)
        let s = setup(download: { target.value = $0 }, defaults: scratch)
        var installed = 0
        s.onInstalled = { installed += 1 }
        await s.downloadSteam()
        #expect(s.stage == .signIn)
        #expect(installed == 1)
        #expect(target.value?.path == "/nonexistent-applications")
    }

    @Test("A failed download says why and offers the button again")
    func downloadFails() async {
        let s = setup(download: { _ in throw Broke() }, defaults: ScratchDefaults())
        await s.downloadSteam()
        #expect(s.stage == .failed("Steam could not be installed: disk full"))
        #expect(!s.isWorking)
    }

    @Test("Locate Steam accepts Valve's app only, and remembers where it is")
    func locate() {
        let scratch = ScratchDefaults()
        let other = setup(bundleID: "com.example.notsteam", defaults: scratch)
        #expect(!other.locate(URL(filePath: "/Volumes/Games/Other.app")))
        #expect(other.stage == .failed("Other.app is not Steam."))
        #expect(scratch.defaults.string(forKey: SupportPaths.Steam.appPathKey) == nil)

        let steam = setup(defaults: scratch)
        #expect(steam.locate(URL(filePath: "/Volumes/Games/Steam.app")))
        #expect(scratch.defaults.string(forKey: SupportPaths.Steam.appPathKey) == "/Volumes/Games/Steam.app")
        #expect(steam.stage == .signIn)
    }

    @Test("The Install Steam screen renders in light and dark, with and without Homebrew")
    func renders() async throws {
        for (brew, name) in [("/opt/homebrew/bin/brew", "steam-not-installed"), (nil, "steam-not-installed-no-homebrew")] {
            let s = setup(brew: brew, defaults: ScratchDefaults())
            for dark in [false, true] {
                let size = snapshot(SteamInstallView(setup: s, locate: { nil }, openSteam: {}).frame(width: 720, height: 560),
                                    named: name, dark: dark)
                #expect(size.width >= 720)
            }
        }
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
