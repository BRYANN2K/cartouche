
import Foundation

enum SettingsLink {
    static let scheme = "x-apple.systempreferences:"
    static let privacyRoot = scheme + "com.apple.preference.security"

    // Anchors macOS dropped on a given major version. Empty while 15 and 26 open them all.
    static let brokenAnchors: [Int: Set<String>] = [:]

    static func anchor(for permission: Permission) -> String? {
        switch permission {
        case .appManagement: "Privacy_AppBundles"
        case .steamInput, .accessibility: "Privacy_Accessibility"
        case .gameInputMonitoring, .inputMonitoring: "Privacy_ListenEvent"
        case .downloads, .removableVolumes: "Privacy_FilesAndFolders"
        case .localNetwork: "Privacy_LocalNetwork"
        case .notifications, .loginItems, .keychain: nil
        }
    }

    static func urls(
        for permission: Permission,
        on system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.bryann2k.cartouche"
    ) -> [URL] {
        var links: [String] = []
        switch permission {
        case .notifications:
            links = [scheme + "com.apple.Notifications-Settings.extension?id=\(bundleID)",
                     scheme + "com.apple.Notifications-Settings.extension", scheme]
        case .loginItems:
            links = [scheme + "com.apple.LoginItems-Settings.extension", scheme]
        case .keychain:
            return []
        default:
            if let anchor = anchor(for: permission),
               brokenAnchors[system.majorVersion]?.contains(anchor) != true {
                links = [privacyRoot + "?" + anchor]
            }
            links.append(privacyRoot)
        }
        return links.compactMap(URL.init(string:))
    }
}
