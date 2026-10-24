// The Add Games sheet's drop, and the way back to it from the flow it opened.

import Foundation
import Observation

@MainActor
@Observable
final class AddGamesNavigation {

    // What the sheet shows; nil shows its empty drop zone
    var drop: DropModel?
    // A drop handed to a flow, kept as it was left for that flow's Back
    private(set) var parked: DropModel?
    @ObservationIgnored private var next: (@MainActor () -> Void)?
    @ObservationIgnored private var returning = false

    var canReturn: Bool { parked != nil }

    // The sheet closes first and open runs once it is gone.
    func handOff(_ open: @escaping @MainActor () -> Void) {
        next = open
    }

    func sheetDismissed() {
        let open = next
        next = nil
        if open == nil {
            drop?.cancel()
            parked = nil
        } else {
            parked = drop
        }
        drop = nil
        open?()
    }

    // Back from a flow's first step, before its sheet closes.
    func returnOnDismiss() {
        returning = canReturn
    }

    // The flow's sheet is gone: true when Add Games should show again.
    func flowDismissed() -> Bool {
        defer { returning = false }
        return returning && restore()
    }

    func restore() -> Bool {
        guard let parked else { return false }
        drop = parked
        self.parked = nil
        return true
    }
}
