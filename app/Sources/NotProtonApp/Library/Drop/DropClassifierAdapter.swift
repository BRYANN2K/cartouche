// The app's drop backend: InstallerKit's DropClassifier over the bundled
// libarchive. Archives stage on the workspace's volume and land in DropStaging
// so the "Use in Place" and "Copy into Cartouche" flows can read them afterwards.

import Foundation
import InstallerKit

struct InstallerKitDropClassifier: DropClassifying {

    // Resolves the bundled libarchive. Called inside classify, which is
    // nonisolated, so locating and dlopening the dylib never touches the
    // main actor.
    let engine: @Sendable () -> ArchiveExtractor?
    let workspace: URL

    init(workspace: URL = SupportPaths.dropStaging,
         engine: (@Sendable () -> ArchiveExtractor?)? = nil) {
        self.workspace = workspace
        self.engine = engine ?? { try? ArchiveExtractor.live() }
    }

    func classify(_ urls: [URL], progress: @escaping @Sendable (DropProgress) -> Void) async throws -> DropResult {
        let extractor = engine()
        let classifier = DropClassifier(extractor: extractor, workspace: workspace)
        let outcome = try await classifier.classify(urls) { p in
            progress(DropProgress(fileName: p.fileName, bytesDone: p.bytesDone,
                                  bytesTotal: p.bytesTotal, secondsLeft: p.secondsLeft))
        }
        return Self.map(outcome, engineAvailable: extractor != nil)
    }

    static func map(_ outcome: DropOutcome, engineAvailable: Bool = true) -> DropResult {
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
            return .mixed(outcomes.map { map($0, engineAvailable: engineAvailable) })
        case .failed(let failure):
            return .failed(map(failure, engineAvailable: engineAvailable))
        }
    }

    static func map(_ failure: DropFailureReason, engineAvailable: Bool = true) -> DropFailure {
        switch failure {
        case .passwordProtected(let url): .passwordProtected(url)
        // With the dylib absent every archive reports unsupported; say what is really wrong.
        case .unsupportedArchive(let url): engineAvailable ? .unsupportedArchive(url) : .detectionUnavailable
        case .damagedArchive(let url): .damagedArchive(url)
        case .missingVolume(let url, let name): .missingVolume(url, name)
        case .insufficientSpace(let url, let needed, let free): .insufficientSpace(url, needed: needed, free: free)
        case .nothingRecognized(let urls): .nothingRecognized(urls)
        }
    }
}
