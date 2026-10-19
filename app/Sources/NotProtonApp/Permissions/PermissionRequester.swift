// The calls that make macOS show its permission prompts. Only PermissionFlow
// reaches them, after Cartouche's explanation.

import AppKit
import ApplicationServices
import Foundation
import IOKit.hid
import Network
import ServiceManagement
import UserNotifications

struct LivePermissionRequester: PermissionRequester {

    func request(_ permission: Permission, target: URL?) async -> SystemAnswer {
        switch permission {
        case .accessibility:
            // The CFString constant is a mutable global in Swift 6, so its value is spelled out
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notGranted
        case .inputMonitoring:
            // macOS answers right away and finishes the decision in System Settings
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? .granted : .undetermined
        case .downloads:
            return await Self.read(URL.downloadsDirectory)
        case .removableVolumes:
            guard let target else { return .unreadable }
            return await Self.read(target)
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .unreadable }
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted == true ? .granted : .denied
        case .localNetwork:
            return await Self.touchLocalNetwork()
        case .loginItems:
            try? SMAppService.mainApp.register()
            switch SMAppService.mainApp.status {
            case .enabled: return .granted
            case .requiresApproval: return .denied
            default: return .undetermined
            }
        case .appManagement, .steamInput, .gameInputMonitoring, .keychain:
            // Not Cartouche's prompt to show: App Management answers a real write,
            // the others belong to Steam and the games
            return .unreadable
        }
    }

    // The first read of a protected folder is what shows the prompt, and it
    // blocks until the user answers
    private static func read(_ folder: URL) async -> SystemAnswer {
        await Task.detached(priority: .userInitiated) {
            LivePermissionProbe.readCheck(folder)
        }.value
    }

    // Browsing for a Bonjour service is the first local network use, which
    // shows the prompt. There is no answer to read back.
    private static func touchLocalNetwork() async -> SystemAnswer {
        let browser = NWBrowser(for: .bonjour(type: "_cartouche._udp", domain: nil), using: .udp)
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(for: .seconds(2))
        browser.cancel()
        return .unreadable
    }
}

extension PermissionCenter {
    static func live() -> PermissionCenter {
        PermissionCenter(probe: LivePermissionProbe(), requester: LivePermissionRequester(),
                         opener: { NSWorkspace.shared.open($0) })
    }
}
