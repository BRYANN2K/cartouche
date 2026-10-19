import Foundation
import Testing

@testable import NotProtonApp

@Suite("Settings > Privacy")
@MainActor
struct PrivacySettingsTests {

    // A fixed mix of answers, so the rows below are the snapshot of the list
    func center(_ scratch: ScratchDefaults, opened: @escaping @MainActor (URL) -> Bool = { _ in true }) -> (PermissionCenter, FakeTCC) {
        scratch.ledger.note(.denied, for: .appManagement)
        let tcc = FakeTCC([
            .accessibility: .notGranted,
            .inputMonitoring: .granted,
            .notifications: .undetermined,
            .loginItems: .denied,
        ], deepOnly: FakeTCC.fileChecks)
        let center = PermissionCenter(probe: tcc, requester: tcc, ledger: scratch.ledger,
                                      opener: opened, notifications: NotificationCenter())
        return (center, tcc)
    }

    @Test("The list shows every permission with its feature and state, and a way to change it once macOS knows Cartouche")
    func listSnapshot() async {
        let scratch = ScratchDefaults()
        let (center, tcc) = center(scratch)
        await center.refresh()

        let lines = PrivacyRow.rows(center).map {
            "\($0.title) | \($0.feature) | \($0.state.label) | \($0.canOpenSettings ? "Open System Settings" : "-")"
        }
        #expect(lines == [
            "App Management | Adds Steam Play to the Steam app | Not allowed | Open System Settings",
            "Accessibility | Steam, for controllers in Steam games | Unknown, will be asked when needed | Open System Settings",
            "Accessibility | Controller for keyboard-only games | Not asked yet | -",
            "Input Monitoring | Windows games, for the keyboard in some games | Unknown, will be asked when needed | Open System Settings",
            "Input Monitoring | Remap the Mac keyboard and mouse per game | Allowed | Open System Settings",
            "Downloads Folder | Suggest installers that appear in Downloads | Not asked yet | -",
            "Removable Volumes | Game folders on an external disk | Not asked yet | -",
            "Local Network | Netplay and LAN games | Not asked yet | -",
            "Notifications | Download finished, install finished, ready to play | Not asked yet | -",
            "Login Items | Open Cartouche at login | Not allowed | Open System Settings",
            "Keychain | Store sign-ins for Epic, GOG, Amazon and RetroAchievements | Allowed | -",
        ])
        #expect(tcc.requests.isEmpty, "opening the list asked macOS")
    }

    @Test("The states read Allowed, Not allowed and Not asked yet")
    func labels() {
        #expect(PermissionState.allowed.label == "Allowed")
        #expect(PermissionState.denied.label == "Not allowed")
        #expect(PermissionState.notAsked.label == "Not asked yet")
    }

    @Test("Recover App Management: Open System Settings, allow, come back, and the row says Allowed without a restart")
    func recoverAppManagement() async {
        let scratch = ScratchDefaults()
        var opened: [String] = []
        let (center, tcc) = center(scratch) { opened.append($0.absoluteString); return true }
        tcc.set(.appManagement, .denied)
        await center.refresh()
        #expect(PrivacyRow.rows(center).first?.state == .denied)

        center.openSettings(for: .appManagement)
        #expect(opened == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"])

        // The user allows Cartouche in System Settings, then switches back
        tcc.set(.appManagement, .granted)
        await center.applicationDidBecomeActive()

        #expect(PrivacyRow.rows(center).first?.state == .allowed)
        #expect(PrivacyRow.rows(center).first?.state.label == "Allowed")
        #expect(tcc.deepReads == [.appManagement])
    }

    @Test("The Privacy list renders in light and dark")
    func renders() async {
        let scratch = ScratchDefaults()
        let (center, _) = center(scratch)
        await center.refresh()
        for dark in [false, true] {
            let size = snapshot(PrivacySettingsView(center: center, choices: PrivacyChoices(defaults: scratch.defaults))
                                .frame(width: 640, height: 760), named: "privacy", dark: dark)
            #expect(size.width >= 640)
        }
    }
}
