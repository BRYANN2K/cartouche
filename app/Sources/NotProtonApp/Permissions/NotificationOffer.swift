// Notifications are offered once, after the first download or install
// finishes. Never at launch.

import Foundation

enum NotificationOffer {

    enum Event: Sendable {
        case launch
        case downloadFinished
        case installFinished
    }

    static func shouldOffer(after event: Event, state: PermissionState, offeredBefore: Bool) -> Bool {
        event != .launch && state == .notAsked && !offeredBefore
    }

    // Downloads and installs call this when they finish
    @MainActor
    static func offer(after event: Event, flow: PermissionFlow, then: @escaping @MainActor (PermissionFlow.Outcome) -> Void = { _ in }) {
        let ledger = flow.center.ledger
        guard shouldOffer(after: event, state: flow.center.state(.notifications),
                          offeredBefore: ledger.offered(.notifications)) else { return }
        ledger.noteOffered(.notifications)
        flow.start(.notifications, then: then)
    }
}
