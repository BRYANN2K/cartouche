import Foundation
import Testing

@testable import NotProtonApp

// Links are checked by construction. Opening them for real is a manual check in evidence.md.
@Suite("System Settings links")
struct SettingsLinkTests {

    static let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    static let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    @Test("Each permission opens its own Privacy & Security pane, then the root", arguments: [sequoia, tahoe])
    func privacyPanes(_ system: OperatingSystemVersion) {
        let expected: [Permission: String] = [
            .appManagement: "Privacy_AppBundles",
            .steamInput: "Privacy_Accessibility",
            .accessibility: "Privacy_Accessibility",
            .gameInputMonitoring: "Privacy_ListenEvent",
            .inputMonitoring: "Privacy_ListenEvent",
            .downloads: "Privacy_FilesAndFolders",
            .removableVolumes: "Privacy_FilesAndFolders",
            .localNetwork: "Privacy_LocalNetwork",
        ]
        for (permission, anchor) in expected {
            let links = SettingsLink.urls(for: permission, on: system).map(\.absoluteString)
            #expect(links == [
                "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
                "x-apple.systempreferences:com.apple.preference.security",
            ], "\(permission)")
        }
    }

    @Test("Notifications and Login Items open their own panes, Keychain has none")
    func otherPanes() {
        let notifications = SettingsLink.urls(for: .notifications, on: Self.tahoe, bundleID: "dev.bryann2k.cartouche")
        #expect(notifications.first?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.bryann2k.cartouche")
        #expect(notifications.last?.absoluteString == "x-apple.systempreferences:")
        #expect(SettingsLink.urls(for: .loginItems, on: Self.tahoe).first?.absoluteString
            == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        #expect(SettingsLink.urls(for: .keychain, on: Self.tahoe).isEmpty)
    }

    @Test("A link macOS does not open falls back to the Privacy & Security root")
    @MainActor
    func fallback() {
        let scratch = ScratchDefaults()
        var opened: [String] = []
        let center = PermissionCenter(
            probe: FakeTCC(), requester: FakeTCC(), ledger: scratch.ledger,
            opener: { url in
                opened.append(url.absoluteString)
                return !url.absoluteString.contains("?")
            },
            system: Self.sequoia, notifications: NotificationCenter())

        #expect(center.openSettings(for: .appManagement))
        #expect(opened == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.preference.security",
        ])
        #expect(scratch.ledger.wantsRecheck(.appManagement))
    }

    @Test("The exact pane is tried once and nothing more when it opens")
    @MainActor
    func exactOnly() {
        let scratch = ScratchDefaults()
        var opened: [URL] = []
        let center = PermissionCenter(
            probe: FakeTCC(), requester: FakeTCC(), ledger: scratch.ledger,
            opener: { opened.append($0); return true }, system: Self.tahoe, notifications: NotificationCenter())
        center.openSettings(for: .downloads)
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"])
    }

    @Test("NotProton's App Management remedy uses the same link")
    func remedyLink() {
        #expect(Remedy.appManagement.settingsPane == SettingsLink.urls(for: .appManagement).first)
        #expect(Remedy.ownership.settingsPane == nil)
    }
}
