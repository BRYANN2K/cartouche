// What a drop on Cartouche turned out to be. The views only read these values; working them out
// (archives, installers, installed games, ROMs) is a DropClassifying backend's job.

import Foundation
import Observation
import RetroArchKit
import SwiftUI

struct DropProgress: Equatable, Sendable {
    var fileName: String
    var bytesDone: Int64
    var bytesTotal: Int64
    var secondsLeft: TimeInterval?

    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

struct DroppedInstaller: Equatable, Sendable {
    var setup: URL
    var name: String
    var parts: Int
}

struct DroppedInstalledGame: Equatable, Sendable {
    var folder: URL
    var name: String
    var steamAppID: Int?
    // Most likely first
    var executables: [URL]
    var onExternalDrive: Bool
    var bytes: Int64
}

struct DroppedConsoleGroup: Equatable, Sendable, Identifiable {
    var console: String
    var files: [URL]
    var id: String { console }
}

struct DroppedROMs: Equatable, Sendable {
    var groups: [DroppedConsoleGroup]
    var unknown: [URL]

    var count: Int { groups.reduce(0) { $0 + $1.files.count } }
}

enum DropFailure: Equatable, Sendable {
    case detectionUnavailable
    case passwordProtected(URL)
    case unsupportedArchive(URL)
    case damagedArchive(URL)
    // A multi-volume archive with a gap in the numbering; the missing file's name.
    case missingVolume(URL, String)
    case insufficientSpace(URL, needed: Int64, free: Int64)
    case nothingRecognized([URL])

    var item: URL? {
        switch self {
        case .detectionUnavailable: nil
        case .passwordProtected(let url), .unsupportedArchive(let url), .damagedArchive(let url),
             .missingVolume(let url, _), .insufficientSpace(let url, needed: _, free: _): url
        case .nothingRecognized(let urls): urls.first
        }
    }
}

indirect enum DropResult: Equatable, Sendable {
    case installer(DroppedInstaller)
    case installedGame(DroppedInstalledGame)
    case roms(DroppedROMs)
    case mixed([DropResult])
    case failed(DropFailure)
}

enum DropPhase: Equatable {
    case detecting(DropProgress?)
    case result(DropResult)
}

enum GameStorage: String, CaseIterable, Identifiable, Sendable {
    case inPlace, copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inPlace: String(localized: "Use in Place")
        case .copy: String(localized: "Copy into Cartouche")
        }
    }
}

// The backend that works out a drop. `progress` is called while an archive is extracted.
protocol DropClassifying: Sendable {
    func classify(_ urls: [URL], progress: @escaping @Sendable (DropProgress) -> Void) async throws -> DropResult
}

// What the drop sheet asks the rest of the app to do with its result
struct DropActions {
    var install: @MainActor (DroppedInstaller) -> Void = { _ in }
    var importGame: @MainActor (DroppedInstalledGame, URL, GameStorage) -> Void = { _, _, _ in }
    var addROMs: @MainActor (DroppedROMs) -> Void = { _ in }
    var addConsole: @MainActor (String) -> Void = { _ in }
    var chooseAnother: @MainActor () -> Void = {}
}

@MainActor
@Observable
final class DropModel {
    var phase: DropPhase?
    var chosenExe: URL?
    var storage: GameStorage = .inPlace

    @ObservationIgnored let classifier: (any DropClassifying)?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(classifier: (any DropClassifying)? = nil) {
        self.classifier = classifier
    }

    var isPresented: Bool {
        get { phase != nil }
        set { if !newValue { cancel() } }
    }

    func start(_ urls: [URL]) {
        work?.cancel()
        phase = .detecting(nil)
        chosenExe = nil
        storage = .inPlace
        guard let classifier else {
            phase = .result(.failed(.detectionUnavailable))
            return
        }
        let report: @Sendable (DropProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .detecting = self.phase else { return }
                self.phase = .detecting(progress)
            }
        }
        work = Task { [weak self] in
            let result: DropResult
            do {
                result = try await classifier.classify(urls, progress: report)
            } catch {
                result = .failed(.nothingRecognized(urls))
            }
            guard let self, !Task.isCancelled else { return }
            if case .installedGame(let game) = result { self.chosenExe = game.executables.first }
            self.phase = .result(result)
        }
    }

    func show(_ result: DropResult) {
        work?.cancel()
        if case .installedGame(let game) = result { chosenExe = game.executables.first }
        phase = .result(result)
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = nil
    }
}

private struct DropClassifierKey: EnvironmentKey {
    static let defaultValue: (any DropClassifying)? = nil
}

extension EnvironmentValues {
    // Nil until the backend lands; the sheet reports detection unavailable.
    var dropClassifier: (any DropClassifying)? {
        get { self[DropClassifierKey.self] }
        set { self[DropClassifierKey.self] = newValue }
    }
}

// Preview and snapshot data for each result the sheet draws
enum DropFixtures {
    static let folder = URL(filePath: "/Volumes/Games/Witcher 3", directoryHint: .isDirectory)

    static let installer = DropResult.installer(DroppedInstaller(
        setup: URL(filePath: "/Users/player/Downloads/The Witcher 3/setup_the_witcher_3.exe"),
        name: "The Witcher 3: Wild Hunt", parts: 4))

    static let installedGame = DropResult.installedGame(DroppedInstalledGame(
        folder: folder, name: "The Witcher 3: Wild Hunt", steamAppID: 292_030,
        executables: [folder.appending(path: "bin/x64/witcher3.exe"), folder.appending(path: "REDprelauncher.exe")],
        onExternalDrive: true, bytes: 52_000_000_000))

    static let roms = DropResult.roms(DroppedROMs(
        groups: [
            DroppedConsoleGroup(console: "snes", files: [URL(filePath: "/ROMs/Chrono Trigger (USA).sfc"),
                                                         URL(filePath: "/ROMs/Super Metroid (USA).sfc")]),
            DroppedConsoleGroup(console: "gba", files: [URL(filePath: "/ROMs/Metroid Fusion (USA).gba")]),
            DroppedConsoleGroup(console: "ps1", files: [URL(filePath: "/ROMs/Final Fantasy VII (Disc 1).chd")]),
        ],
        unknown: [URL(filePath: "/ROMs/readme.txt")]))

    static let mixed = DropResult.mixed([installer, roms])

    static let extracting = DropProgress(fileName: "Chrono Trigger Collection.7z", bytesDone: 412_000_000,
                                         bytesTotal: 1_100_000_000, secondsLeft: 38)

    static let failures: [DropResult] = [
        .failed(.passwordProtected(URL(filePath: "/Users/player/Downloads/Game.rar"))),
        .failed(.damagedArchive(URL(filePath: "/Users/player/Downloads/Game.zip"))),
        .failed(.unsupportedArchive(URL(filePath: "/Users/player/Downloads/Game.sit"))),
        .failed(.missingVolume(URL(filePath: "/Users/player/Downloads/game.part1.rar"), "game.part2.rar")),
        .failed(.insufficientSpace(URL(filePath: "/Users/player/Downloads/Game.7z"),
                                   needed: 52_000_000_000, free: 11_000_000_000)),
        .failed(.nothingRecognized([URL(filePath: "/Users/player/Documents/Notes")])),
    ]
}

struct FixtureDropClassifier: DropClassifying {
    let result: DropResult

    func classify(_ urls: [URL], progress: @escaping @Sendable (DropProgress) -> Void) async throws -> DropResult {
        progress(DropFixtures.extracting)
        return result
    }
}
