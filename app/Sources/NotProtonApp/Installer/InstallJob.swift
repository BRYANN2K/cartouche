// One install from a Windows installer, from the checks to the exe choice.
// The job lives in InstallCenter, not in the sheet, so closing the sheet never
// stops it.

import Foundation
import InstallerKit
import Observation

// What the review step hands to the install.
struct InstallRequest: Sendable {
    let setup: URL
    let source: URL
    let name: String
    let appID: Int?
    let gogID: String?
    let expectedBytes: Int64
    // setup.exe and its parts, for the cleanup line.
    let installerBytes: Int64
    let installerFiles: [URL]
    let manifest: ChecksumManifest?
}

enum GameInstallPhase: Sendable, Equatable {
    case waiting
    case verifying
    case preparing
    case installing
    case redistributables
    // Installed; the user confirms which exe starts the game.
    case choosing
    case ready
    case failed
    case stopped
}

@MainActor
@Observable
final class InstallJob: Identifiable {

    let id = UUID()
    let request: InstallRequest
    var inputs: InstallInputs
    var phase: GameInstallPhase = .waiting
    var progress = InstallProgress()
    // Set when the installer itself failed.
    var diagnosis: InstallDiagnosis?
    // Set when Cartouche could not get as far as the installer.
    var problem: String?
    var folder: GameFolder?
    var installFolder: URL?
    var candidates: [ExeDetector.Candidate] = []
    var redistributables: [Redistributable] = []
    // Nil when there were none to install.
    var redistributablesInstalled: Bool?
    var game: InstalledGame?
    // Fixes already tried, so each is offered once.
    var tried: [RetryFix] = []

    @ObservationIgnored var run: InstallRun?
    @ObservationIgnored var task: Task<Void, Never>?

    init(request: InstallRequest, inputs: InstallInputs) {
        self.request = request
        self.inputs = inputs
    }

    var title: String { request.name }

    var isRunning: Bool {
        [.verifying, .preparing, .installing, .redistributables].contains(phase)
    }

    var isStuck: Bool { phase == .installing && progress.stuck }

    func fail(_ message: String) {
        problem = message
        phase = .failed
    }

    // The retries the diagnosis offers that still change something.
    func availableFixes(runners: [String]) -> [RetryFix] {
        (diagnosis?.fixes ?? []).filter { inputs.applying($0, runners: runners) != nil }
    }
}
