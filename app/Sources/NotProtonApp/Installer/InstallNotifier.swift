// "<Game> is installed" with an Open button, when the install finishes while
// the sheet is closed. Posts only if notifications are already allowed: the
// prompt itself comes from NotificationOffer, after Cartouche's explanation.

import Foundation
import UserNotifications

@MainActor
protocol InstallNotifying: AnyObject {
    func installed(name: String, job: UUID)
}

@MainActor
final class UserInstallNotifier: NSObject, InstallNotifying, @preconcurrency UNUserNotificationCenterDelegate {

    static let category = "install-finished"
    static let openAction = "open"

    // Called with the job's ID when the user clicks Open.
    var onOpen: (UUID) -> Void = { _ in }

    // A command-line or test build has no bundle, and UNUserNotificationCenter needs one.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func installed(name: String, job: UUID) {
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: String(localized: "Open"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [open], intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(name) is installed")
        content.body = String(localized: "Choose which file starts the game.")
        content.categoryIdentifier = Self.category
        content.userInfo = ["job": job.uuidString]
        let request = UNNotificationRequest(identifier: job.uuidString, content: content, trigger: nil)
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            try? await center.add(request)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void
    ) {
        if let id = (response.notification.request.content.userInfo["job"] as? String).flatMap(UUID.init(uuidString:)) {
            onOpen(id)
        }
        done()
    }
}
