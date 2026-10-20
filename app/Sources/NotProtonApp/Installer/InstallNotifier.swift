// Posts only if notifications are already allowed; the prompt comes from NotificationOffer.

import Foundation

@MainActor
protocol InstallNotifying: AnyObject {
    func installed(name: String, job: UUID)
    func failed(name: String, job: UUID)
}

@MainActor
final class UserInstallNotifier: InstallNotifying {

    static let category = "install-finished"
    static let failedCategory = "install-failed"
    static let openAction = "open"

    var onOpen: (UUID) -> Void = { _ in }

    let poster: any NotificationPosting

    init(poster: (any NotificationPosting)? = nil, router: NotificationRouter? = nil) {
        let router = router ?? .shared
        self.poster = poster ?? router
        for category in [Self.category, Self.failedCategory] {
            router.handle(category: category) { [weak self] _, info in
                if let id = info["job"].flatMap(UUID.init(uuidString:)) { self?.onOpen(id) }
            }
        }
    }

    func installed(name: String, job: UUID) {
        poster.post(NotificationSpec(
            identifier: job.uuidString, title: String(localized: "\(name) is installed"),
            body: String(localized: "Choose which file starts the game."), category: Self.category,
            action: Self.openAction, actionTitle: String(localized: "Open"), userInfo: ["job": job.uuidString]))
    }

    func failed(name: String, job: UUID) {
        poster.post(NotificationSpec(
            identifier: "failed-\(job.uuidString)", title: String(localized: "\(name) could not be installed"),
            body: String(localized: "Open Cartouche to see why and try again."), category: Self.failedCategory,
            action: Self.openAction, actionTitle: String(localized: "Open"), userInfo: ["job": job.uuidString]))
    }
}
