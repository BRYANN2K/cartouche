
import Foundation

struct ScreenRoute: Codable, Hashable, Sendable {
    var screen: String
    var detail: String?
    var finishing: Permission?

    static func onboarding(step: String) -> ScreenRoute {
        ScreenRoute(screen: "onboarding", detail: step)
    }

    static func controls(game: String, finishing: Permission? = nil) -> ScreenRoute {
        ScreenRoute(screen: "controls", detail: game, finishing: finishing)
    }

    static let pcGamesStep = "pcGames"
}
