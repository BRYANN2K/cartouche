// The job lives in InstallCenter, not the sheet, so closing it never stops the install.

import Foundation
import InstallerKit
import Observation

struct InstallRequest: Sendable {
    var setup: URL
    var source: URL
    let name: String
    let appID: Int?
    let gogID: String?
    let expectedBytes: Int64
    let installerBytes: Int64
    var installerFiles: [URL]
    var manifest: ChecksumManifest?
    // Set when the analysis found an installer that uses an external unpacker.
    var unpacker: ExternalUnpacker? = nil
    // Set when the parts can be unpacked directly by the driver, without the setup running.
    var directUnpack: DirectUnpackPlan? = nil
    // Set for a game that is already installed: nothing from its folder runs, the folder is used in place or copied.
    var importing: GameImport? = nil
}

struct GameImport: Sendable, Equatable {
    var folder: URL
    var exe: URL
    var copy: Bool
    var showInSteam: Bool
}

enum GameInstallPhase: Sendable, Equatable {
    case waiting
    case verifying
    case preparing
    case installing
    case redistributables
    case choosing
    case ready
    case failed
    case stopped
}

@MainActor
@Observable
final class InstallJob: Identifiable {

    let id = UUID()
    var request: InstallRequest
    var inputs: InstallInputs
    var phase: GameInstallPhase = .waiting
    var progress = InstallProgress()
    var diagnosis: InstallDiagnosis?
    var problem: String?
    var folder: GameFolder?
    var installFolder: URL?
    var candidates: [ExeDetector.Candidate] = []
    // The runtimes to install, one winetricks verb each; skipRuntime asks the engine to abandon the current one.
    var runtimeSteps: [RuntimeStep] = []
    var skipRuntime = false
    // Nil until the external-unpacker preparation ran, then whether it succeeded.
    var unpackerPrepInstalled: Bool?
    var game: InstalledGame?
    var steamOutcome: SteamShortcuts.Outcome?
    var tried: [RetryFix] = []
    // The output check's outcome (ADR 0025/0026): written into the record when the job finishes.
    var verification: VerificationOutcome?
    // Where the check ran — the game folder for imports, the install dir inside the prefix otherwise.
    var verificationDir: URL?
    // How far the mismatch fallback got: 0 = original run, 1 = shipped helpers with their
    // original settings, 2 = guided real installer under Wine (the last resort).
    var verificationFallback = 0
    // When the prefix's first boot started — the "Preparing Windows environment" phase's elapsed time.
    var bootStarted: Date?
    // The boot's prefix.log once the file exists; the check runs off the main actor so views never stat it.
    var bootLog: URL?

    @ObservationIgnored var run: InstallRun?
    @ObservationIgnored var task: Task<Void, Never>?

    init(request: InstallRequest, inputs: InstallInputs) {
        self.request = request
        self.inputs = inputs
    }

    var title: String { request.name }

    // The verification outcome as it lands in the install record; nil while the check hasn't run.
    var verificationRecord: VerificationRecord? {
        guard let outcome = verification, let dir = verificationDir else { return nil }
        return VerificationRecord(outcome: outcome, gameDir: dir)
    }

    var isRunning: Bool {
        [.verifying, .preparing, .installing, .redistributables].contains(phase)
    }

    var isStuck: Bool { phase == .installing && progress.stuck }

    var canShowInstallerWindow: Bool {
        request.importing == nil && request.directUnpack == nil && inputs.mode == .guided
    }

    func fail(_ message: String) {
        problem = message
        phase = .failed
    }

    // Point the whole request at a copy of the installer folder (copy_to_internal_disk): setup, parts and manifest move together.
    func moveSource(to folder: URL) {
        let old = request.source.standardizedFileURL.path(percentEncoded: false)
        func rebased(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.hasPrefix(old + "/") ? folder.appending(path: String(path.dropFirst(old.count + 1))) : url
        }
        request.source = folder
        request.setup = rebased(request.setup)
        request.installerFiles = request.installerFiles.map(rebased)
        if let manifest = request.manifest {
            request.manifest = ChecksumManifest(
                source: rebased(manifest.source),
                entries: manifest.entries.map { ChecksumEntry(md5: $0.md5, file: rebased($0.file)) },
                mentionsOptionalParts: manifest.mentionsOptionalParts)
        }
    }

    func availableFixes(runners: [String]) -> [RetryFix] {
        (diagnosis?.fixes ?? []).filter { inputs.applying($0, runners: runners) != nil }
    }
}
