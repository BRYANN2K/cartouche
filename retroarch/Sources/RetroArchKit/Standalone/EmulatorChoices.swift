import Foundation
import Observation

extension RetroArchPaths {
    public var emulatorChoices: URL { root.appending(path: "emulators.json") }
}

public enum ConsoleRoute: Sendable, Equatable {
    case retroArch
    case standalone(InstalledEmulator)
    case missing(StandaloneEmulator)

    public var emulator: InstalledEmulator? {
        if case .standalone(let installed) = self { return installed }
        return nil
    }

    public var missingText: String? {
        guard case .missing(let emulator) = self else { return nil }
        return String(localized: "\(emulator.name) is not installed", bundle: .module)
    }

    // A chosen-but-gone emulator falls back to RetroArch when its core is here, else is named not installed; with no choice, a detected emulator wins.
    public static func resolve(
        _ console: Console, choice: String?, installed: [InstalledEmulator], coreReady: Bool
    ) -> ConsoleRoute {
        let mine = installed.filter { $0.emulator.consoles.contains(console.id) }
        switch choice {
        case EmulatorChoice.retroArch? where console.hasCore:
            return .retroArch
        case let id? where id != EmulatorChoice.retroArch:
            if let found = mine.first(where: { $0.id == id }) { return .standalone(found) }
            if let wanted = EmulatorCatalog.emulator(id), wanted.consoles.contains(console.id) {
                return console.hasCore && coreReady ? .retroArch : .missing(wanted)
            }
        default:
            break
        }
        if let first = mine.first { return .standalone(first) }
        if console.hasCore { return .retroArch }
        if let wanted = EmulatorCatalog.emulators(for: console.id).first { return .missing(wanted) }
        return .retroArch
    }
}

public struct EmulatorChoice: Sendable, Equatable, Hashable, Identifiable {
    public static let retroArch = "retroarch"

    // "retroarch" or an emulator id
    public var id: String
    public var title: String
}

@MainActor
@Observable
public final class EmulatorShelf {

    public let paths: RetroArchPaths
    public private(set) var installed: [InstalledEmulator] = []
    public private(set) var choices: [String: String] = [:]
    public private(set) var hasLooked = false

    @ObservationIgnored public var detector: EmulatorDetector

    public init(paths: RetroArchPaths, detector: EmulatorDetector = EmulatorDetector()) {
        self.paths = paths
        self.detector = detector
        choices = Self.load(paths)
    }

    public func refresh() async {
        let detector = detector
        installed = await Task.detached { detector.installed() }.value
        hasLooked = true
    }

    public func choice(for console: Console) -> String? { choices[console.id] }

    public func route(for console: Console) -> ConsoleRoute {
        ConsoleRoute.resolve(console, choice: choices[console.id], installed: installed, coreReady: coreReady(console))
    }

    public func coreReady(_ console: Console) -> Bool {
        console.hasCore && FileManager.default.fileExists(
            atPath: paths.cores.appending(path: console.coreFile).path(percentEncoded: false))
    }

    public func options(for console: Console) -> [EmulatorChoice] {
        var options: [EmulatorChoice] = []
        if console.hasCore {
            options.append(EmulatorChoice(id: EmulatorChoice.retroArch,
                                          title: String(localized: "RetroArch (\(console.coreName))", bundle: .module)))
        }
        for found in installed where found.emulator.consoles.contains(console.id) {
            options.append(EmulatorChoice(id: found.id, title: found.title))
        }
        let current = selected(for: console)
        if !options.contains(where: { $0.id == current }), let gone = EmulatorCatalog.emulator(current) {
            options.append(EmulatorChoice(id: gone.id, title: String(localized: "\(gone.name) (not installed)", bundle: .module)))
        }
        return options
    }

    public func selected(for console: Console) -> String {
        if let saved = choices[console.id] { return saved }
        switch route(for: console) {
        case .retroArch: return EmulatorChoice.retroArch
        case .standalone(let found): return found.id
        case .missing(let emulator): return emulator.id
        }
    }

    public func choose(_ id: String, for console: Console) {
        choices[console.id] = id
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(choices).write(to: paths.emulatorChoices, options: .atomic)
    }

    public func consoleNames(of found: InstalledEmulator) -> String {
        found.emulator.consoles.compactMap { ConsoleCatalog.console($0)?.name }
            .formatted(.list(type: .and, width: .narrow))
    }

    private static func load(_ paths: RetroArchPaths) -> [String: String] {
        (try? Data(contentsOf: paths.emulatorChoices)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}
