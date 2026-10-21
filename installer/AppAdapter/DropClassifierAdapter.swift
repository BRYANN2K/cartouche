// NOT COMPILED YET — this file is the thin adapter between InstallerKit's
// DropClassifier and the app's DropClassifying protocol. It compiles only once
// the UI branch lands: move it to app/Sources/NotProtonApp/Library/Drop/
// DropClassifierAdapter.swift after the merge and it builds as part of the app.

import Foundation
import InstallerKit

// Where archives unpack for classification; the extracted folders stay put so
// "Use in Place" and "Copy into Cartouche" can read them afterwards.
struct InstallerKitDropClassifier: DropClassifying {

    let classifier: DropClassifier

    init(workspace: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appending(path: "Cartouche/DropStaging", directoryHint: .isDirectory)) {
        classifier = DropClassifier(extractor: try? ArchiveExtractor.live(), workspace: workspace)
    }

    func classify(_ urls: [URL], progress: @escaping @Sendable (DropProgress) -> Void) async throws -> DropResult {
        let outcome = try await classifier.classify(urls) { p in
            progress(DropProgress(fileName: p.fileName, bytesDone: p.bytesDone,
                                  bytesTotal: p.bytesTotal, secondsLeft: p.secondsLeft))
        }
        return Self.map(outcome)
    }

    static func map(_ outcome: InstallerKit.DropOutcome) -> DropResult {
        switch outcome {
        case .installer(let i):
            return .installer(DroppedInstaller(setup: i.setup, name: i.name, parts: i.parts))
        case .installedGame(let g):
            return .installedGame(DroppedInstalledGame(
                folder: g.folder, name: g.name, steamAppID: g.steamAppID,
                executables: g.executables, onExternalDrive: g.onExternalDrive, bytes: g.bytes))
        case .roms(let r):
            return .roms(DroppedROMs(
                groups: r.groups.map { DroppedConsoleGroup(console: $0.console, files: $0.files) },
                unknown: r.unknown))
        case .mixed(let outcomes):
            return .mixed(outcomes.map(map))
        case .failed(let failure):
            return .failed(map(failure))
        }
    }

    static func map(_ failure: InstallerKit.DropFailureReason) -> DropFailure {
        switch failure {
        case .passwordProtected(let url): .passwordProtected(url)
        case .unsupportedArchive(let url): .unsupportedArchive(url)
        case .damagedArchive(let url): .damagedArchive(url)
        // No dedicated case on the UI side yet: these read as a broken archive.
        case .missingVolume(let url, _), .insufficientSpace(let url, _, _): .damagedArchive(url)
        case .nothingRecognized(let urls): .nothingRecognized(urls)
        }
    }
}
