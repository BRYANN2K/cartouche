import Foundation
import Observation
import SwiftUI

enum GameVerificationStatus: Equatable, Sendable {
    case notVerified, sizes, full

    var title: String {
        switch self {
        case .notVerified: String(localized: "Installed, not verified")
        case .sizes: String(localized: "Verified (sizes)")
        case .full: String(localized: "Verified")
        }
    }

    var detail: String {
        switch self {
        case .notVerified: String(localized: "These game files have not been verified.")
        case .sizes: String(localized: "File presence and sizes match. Contents have not been checked.")
        case .full: String(localized: "Game files passed checksum or archive CRC verification.")
        }
    }
}

struct GameVerificationProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var file: String
    var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
}

struct GameVerificationMismatch: Identifiable, Equatable, Sendable {
    var gameID: String
    var files: [String]
    var id: String { gameID }
}

@MainActor
protocol GameVerificationPresenting: AnyObject, Observable, Sendable {
    func status(for gameID: String) -> GameVerificationStatus
    func progress(for gameID: String) -> GameVerificationProgress?
    var mismatch: GameVerificationMismatch? { get }
    func verify(_ game: Game)
    func stop(gameID: String)
    func retryStandard(gameID: String)
    func keepAnyway(gameID: String)
    func cancelMismatch(gameID: String)
}

private struct GameVerificationKey: EnvironmentKey {
    static let defaultValue: (any GameVerificationPresenting)? = nil
}

extension EnvironmentValues {
    var gameVerification: (any GameVerificationPresenting)? {
        get { self[GameVerificationKey.self] }
        set { self[GameVerificationKey.self] = newValue }
    }
}

@MainActor
@Observable
final class FixtureGameVerification: GameVerificationPresenting {
    var statuses: [String: GameVerificationStatus] = [:]
    var running: [String: GameVerificationProgress] = [:]
    var mismatch: GameVerificationMismatch?
    private(set) var retried: String?

    func status(for gameID: String) -> GameVerificationStatus { statuses[gameID] ?? .notVerified }
    func progress(for gameID: String) -> GameVerificationProgress? { running[gameID] }
    func verify(_ game: Game) {
        statuses[game.id] = .notVerified
        running[game.id] = .init(completed: 0, total: 12, file: "data/game.pak")
    }
    func stop(gameID: String) {
        running[gameID] = nil
        statuses[gameID] = .notVerified
    }
    func retryStandard(gameID: String) {
        cancelMismatch(gameID: gameID)
        retried = gameID
    }
    func keepAnyway(gameID: String) { cancelMismatch(gameID: gameID) }
    func cancelMismatch(gameID: String) {
        mismatch = nil
        statuses[gameID] = .notVerified
    }
}
