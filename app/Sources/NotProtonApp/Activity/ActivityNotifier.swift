// They go out only when notifications are already allowed; the prompt comes from NotificationOffer.

import AppKit
import Foundation
import UserNotifications

struct NotificationButton: Equatable, Sendable {
    let id: String
    let title: String
    // The Mac must be unlocked first, for actions that run programs
    var requiresUnlock = false
}

struct NotificationSpec: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let category: String
    let actions: [NotificationButton]
    let userInfo: [String: String]

    var action: String { actions.first?.id ?? "" }
    var actionTitle: String { actions.first?.title ?? "" }

    init(identifier: String, title: String, body: String, category: String,
         action: String, actionTitle: String, userInfo: [String: String]) {
        self.init(identifier: identifier, title: title, body: body, category: category,
                  actions: [NotificationButton(id: action, title: actionTitle)], userInfo: userInfo)
    }

    init(identifier: String, title: String, body: String, category: String,
         actions: [NotificationButton], userInfo: [String: String]) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.category = category
        self.actions = actions
        self.userInfo = userInfo
    }
}

@MainActor
protocol NotificationPosting: AnyObject {
    func post(_ spec: NotificationSpec)
}

// UNUserNotificationCenter has a single delegate, so every notification of the app goes through this one and its action reaches the handler of its category.
@MainActor
final class NotificationRouter: NSObject, NotificationPosting, @preconcurrency UNUserNotificationCenterDelegate {

    static let shared = NotificationRouter()

    private var handlers: [String: @MainActor (String, [String: String]) -> Void] = [:]
    private var categories: [String: UNNotificationCategory] = [:]

    // A command-line or test build has no bundle, and UNUserNotificationCenter needs one
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func install() {
        center?.delegate = self
    }

    func handle(category: String, _ handler: @escaping @MainActor (String, [String: String]) -> Void) {
        handlers[category] = handler
    }

    func post(_ spec: NotificationSpec) {
        guard let center else { return }
        center.delegate = self
        categories[spec.category] = UNNotificationCategory(
            identifier: spec.category,
            actions: spec.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title,
                                                 options: $0.requiresUnlock ? [.foreground, .authenticationRequired] : [.foreground]) },
            intentIdentifiers: [])
        center.setNotificationCategories(Set(categories.values))
        let content = UNMutableNotificationContent()
        content.title = spec.title
        content.body = spec.body
        content.categoryIdentifier = spec.category
        content.userInfo = spec.userInfo
        let request = UNNotificationRequest(identifier: spec.identifier, content: content, trigger: nil)
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            try? await center.add(request)
        }
    }

    func respond(category: String, action: String, userInfo: [String: String]) {
        handlers[category]?(action, userInfo)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let info = content.userInfo.reduce(into: [String: String]()) { out, pair in
            if let key = pair.key as? String, let value = pair.value as? String { out[key] = value }
        }
        respond(category: content.categoryIdentifier, action: response.actionIdentifier, userInfo: info)
        done()
    }
}

@MainActor
protocol ActivityNotifying: AnyObject {
    func ready(name: String, appID: Int)
    func downloadFailed(name: String, appID: Int, reason: String)
}

@MainActor
final class UserActivityNotifier: ActivityNotifying {

    static let readyCategory = "download-finished"
    static let failedCategory = "download-failed"
    static let playAction = "play"
    static let retryAction = "retry"

    let poster: any NotificationPosting
    var open: @MainActor (URL) -> Void

    init(poster: (any NotificationPosting)? = nil, router: NotificationRouter? = nil,
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        let router = router ?? .shared
        self.poster = poster ?? router
        self.open = open
        router.handle(category: Self.readyCategory) { [weak self] action, info in self?.respond(action, info) }
        router.handle(category: Self.failedCategory) { [weak self] action, info in self?.respond(action, info) }
    }

    func ready(name: String, appID: Int) {
        poster.post(Self.readySpec(name: name, appID: appID))
    }

    func downloadFailed(name: String, appID: Int, reason: String) {
        poster.post(Self.failedSpec(name: name, appID: appID, reason: reason))
    }

    static func readySpec(name: String, appID: Int) -> NotificationSpec {
        NotificationSpec(identifier: "ready-\(appID)", title: String(localized: "\(name) is ready to play"),
                         body: String(localized: "Steam finished downloading it."), category: readyCategory,
                         action: playAction, actionTitle: String(localized: "Play"), userInfo: ["appid": String(appID)])
    }

    static func failedSpec(name: String, appID: Int, reason: String) -> NotificationSpec {
        NotificationSpec(identifier: "failed-\(appID)", title: String(localized: "\(name) could not be downloaded"),
                         body: reason, category: failedCategory, action: retryAction,
                         actionTitle: String(localized: "Try Again"), userInfo: ["appid": String(appID)])
    }

    // Play starts the game through Steam, Try Again queues the download again, a click on the banner opens Cartouche
    func respond(_ action: String, _ info: [String: String]) {
        guard let appID = info["appid"].flatMap(Int.init) else { return }
        switch action {
        case Self.playAction:
            open(URL(string: "steam://rungameid/\(appID)")!)
        case Self.retryAction:
            open(URL(string: "steam://install/\(appID)")!)
        default:
            NSApp?.activate()
        }
    }
}
