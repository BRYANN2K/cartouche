// Where the user was, so a relaunch reopens there.

import Foundation

struct ScreenRoute: Codable, Hashable, Sendable {
    // A Pane raw value, "onboarding" or "controls"
    var screen: String
    // The onboarding step, or the game whose controls were open
    var detail: String?
    // The permission the relaunch is for, so its feature turns on without asking again
    var finishing: Permission?

    static func onboarding(step: String) -> ScreenRoute {
        ScreenRoute(screen: "onboarding", detail: step)
    }

    static func controls(game: String, finishing: Permission? = nil) -> ScreenRoute {
        ScreenRoute(screen: "controls", detail: game, finishing: finishing)
    }

    static let pcGamesStep = "pcGames"
}
