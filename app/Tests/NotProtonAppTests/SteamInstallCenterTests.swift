import Testing

@testable import NotProtonApp

@Suite("Steam background install messages")
struct SteamInstallCenterTests {

    @Test("Worker codes become what the player can do; unknown text passes through")
    @MainActor
    func explain() {
        #expect(SteamInstallCenter.explain("another-install").contains("Downloads"))
        #expect(SteamInstallCenter.explain("steam-timeout").hasPrefix("Steam did not answer"))
        #expect(SteamInstallCenter.explain("integration-update-required").contains("Settings > Steam"))
        #expect(SteamInstallCenter.explain("license-changed").contains("license"))
        #expect(SteamInstallCenter.explain("steam-5") == "steam-5")
    }
}
