// Reading permission states from macOS without ever prompting.

import ApplicationServices
import Foundation
import IOKit.hid
import ServiceManagement
import UserNotifications

protocol PermissionProbe: Sendable {
    // `deep` allows a real read or write, which only runs once the user already decided (Cartouche asked before), so it cannot prompt.
    func answer(for permission: Permission, deep: Bool, target: URL?) async -> SystemAnswer
}

struct LivePermissionProbe: PermissionProbe {
    var steamApp: @Sendable () -> URL = { SupportPaths.Steam.app }

    func answer(for permission: Permission, deep: Bool, target: URL?) async -> SystemAnswer {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .undetermined
            }
        case .notifications:
            // UNUserNotificationCenter traps in a process that is not an app bundle
            guard Bundle.main.bundleIdentifier != nil else { return .unreadable }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .unreadable
            }
        case .loginItems:
            switch SMAppService.mainApp.status {
            case .enabled: return .granted
            case .requiresApproval: return .denied
            case .notRegistered, .notFound: return .undetermined
            @unknown default: return .unreadable
            }
        case .appManagement:
            return deep ? Self.writeCheck(inside: steamApp()) : .unreadable
        case .downloads:
            return deep ? Self.readCheck(URL.downloadsDirectory) : .unreadable
        case .removableVolumes:
            guard deep, let target else { return .unreadable }
            return Self.readCheck(target)
        case .steamInput, .gameInputMonitoring, .localNetwork, .keychain:
            return .unreadable
        }
    }

    static func writeCheck(inside app: URL) -> SystemAnswer {
        let contents = app.appending(path: "Contents")
        let path = contents.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return .unreadable }
        if let owner = Remedy.owner(of: path), owner != getuid() { return .unreadable }
        let probe = contents.appending(path: ".cartouche-access-check").path(percentEncoded: false)
        let fd = open(probe, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        guard fd >= 0 else {
            return errno == EPERM || errno == EACCES ? .denied : .unreadable
        }
        close(fd)
        unlink(probe)
        return .granted
    }

    static func readCheck(_ folder: URL) -> SystemAnswer {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            return .granted
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            return .denied
        } catch {
            return .unreadable
        }
    }
}
