import Foundation
import Observation

// A feature as Settings and the game panel show it for the chosen build
public struct FeatureRow: Sendable, Equatable, Identifiable {
    public var feature: ConsoleFeature
    public var available: Bool

    public var id: String { feature.id }
    public var title: String { feature.title }

    // Shown beside the feature when the chosen build cannot do it
    public var note: String? { available ? nil : ConsolesSettingsModel.needsIncluded }
}

public struct ConsoleRow: Sendable, Equatable, Identifiable {
    public var console: Console
    public var core: CoreCheck
    public var bios: BIOSStatus

    public var id: String { console.id }

    public var coreText: String {
        switch core {
        case .verified: String(localized: "Core ready", bundle: .module)
        case .missing: String(localized: "Core not downloaded", bundle: .module)
        case .unrecorded, .changed: String(localized: "Core changed since it was downloaded", bundle: .module)
        }
    }
}

// Settings > Consoles: which RetroArch runs, what it can do, and the consoles
// the user added. The Settings window that shows it belongs to the app.
@MainActor
@Observable
public final class ConsolesSettingsModel {

    public nonisolated static var needsIncluded: String { String(localized: "Needs the included RetroArch", bundle: .module) }

    public enum BuildState: Sendable, Equatable {
        case checking
        case ready(RetroArchCapabilities)
        case notFound
        case failed(String)
    }

    public typealias Probe = @Sendable (URL) async -> RetroArchCapabilities?

    public let paths: RetroArchPaths
    public let includedApp: URL

    public private(set) var choice: RetroArchChoice = .included
    public private(set) var build: BuildState = .checking
    public private(set) var consoles: [ConsoleRow] = []
    public private(set) var working = false
    public var problem: String?

    @ObservationIgnored private let cores: CoreManager
    @ObservationIgnored private let shelf: ConsoleShelf
    @ObservationIgnored private let official: OfficialRelease
    @ObservationIgnored private let probe: Probe

    public init(
        paths: RetroArchPaths, includedApp: URL, cores: CoreManager, official: OfficialRelease,
        probe: Probe? = nil
    ) {
        self.paths = paths
        self.includedApp = includedApp
        self.cores = cores
        self.shelf = ConsoleShelf(paths: paths, cores: cores)
        self.official = official
        // Probed in Cartouche's own RetroArch home, as it is launched
        self.probe = probe ?? { [home = paths.home] in await BuildProbe.capabilities(of: $0, home: home) }
        choice = Self.savedChoice(paths) ?? .included
    }

    public var capabilities: RetroArchCapabilities? {
        if case .ready(let capabilities) = build { return capabilities }
        return nil
    }

    public var features: [FeatureRow] {
        ConsoleFeature.allCases.map { FeatureRow(feature: $0, available: $0.available(with: capabilities)) }
    }

    // What the picker offers: the included build, each official release, and
    // the user's own copy once they chose one
    public var choices: [RetroArchChoice] {
        var choices: [RetroArchChoice] = [.included] + OfficialRelease.versions.map { .official(version: $0) }
        if case .custom = choice { choices.append(choice) }
        return choices
    }

    public static func title(_ choice: RetroArchChoice) -> String {
        switch choice {
        case .included: String(localized: "Included with Cartouche", bundle: .module)
        case .official(let version): String(localized: "Official release \(version)", bundle: .module)
        case .custom(let path): String(localized: "Your own copy: \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)", bundle: .module)
        }
    }

    public var buildText: String {
        switch build {
        case .checking: String(localized: "Checking RetroArch…", bundle: .module)
        case .notFound: String(localized: "RetroArch is not there.", bundle: .module)
        case .failed(let reason): reason
        case .ready(let capabilities):
            capabilities.mcp
                ? String(localized: "RetroArch \(capabilities.version ?? "") with MCP", bundle: .module)
                : String(localized: "RetroArch \(capabilities.version ?? "") without MCP: games start, Cartouche cannot drive them", bundle: .module)
        }
    }

    // The app of the current choice, nil while an official release is not downloaded
    public var app: URL? {
        switch choice {
        case .included: includedApp
        case .official(let version): official.isInstalled(version) ? official.app(version) : nil
        case .custom(let path): URL(fileURLWithPath: path)
        }
    }

    // The environment RetroArch starts from; its HOME is Cartouche's either way
    public var launchEnvironment: [String: String]?

    public var launcher: ConsoleLauncher? {
        guard let app, let capabilities else { return nil }
        var launcher = ConsoleLauncher(paths: paths, app: app, capabilities: capabilities)
        launcher.environment = launchEnvironment
        return launcher
    }

    // What is shown stays until the new answer is in, so the pane does not flicker
    public func refresh() async {
        if let app, let found = await probe(app) {
            build = .ready(found)
        } else {
            build = .notFound
        }
        await refreshConsoles()
    }

    public func select(_ choice: RetroArchChoice) async {
        problem = nil
        self.choice = choice
        save()
        build = .checking
        if case .official(let version) = choice, !official.isInstalled(version) {
            working = true
            defer { working = false }
            do {
                try await official.install(version)
            } catch {
                build = .failed(error.localizedDescription)
                return
            }
        }
        await refresh()
    }

    public func chooseOwnCopy(_ app: URL) async {
        await select(.custom(path: app.path(percentEncoded: false)))
    }

    public func add(_ console: Console) async {
        await change { try await self.shelf.add(console.id) }
    }

    public func remove(_ console: Console) async {
        await change { try await self.shelf.remove(console.id) }
    }

    public func updateCore(of console: Console) async {
        await change { try await self.cores.update(console.core) }
    }

    public var addable: [Console] {
        ConsoleCatalog.all.filter { console in !consoles.contains { $0.id == console.id } }
    }

    private func change(_ work: @escaping @Sendable () async throws -> Void) async {
        problem = nil
        working = true
        defer { working = false }
        do {
            try await work()
        } catch {
            problem = error.localizedDescription
        }
        await refreshConsoles()
    }

    private func refreshConsoles() async {
        let checker = BIOSChecker(paths: paths)
        var rows: [ConsoleRow] = []
        for console in await shelf.added() {
            rows.append(ConsoleRow(console: console, core: await cores.check(console.core), bios: checker.status(for: console)))
        }
        consoles = rows
    }

    private struct Saved: Codable {
        var retroarch: RetroArchChoice
    }

    private static func savedChoice(_ paths: RetroArchPaths) -> RetroArchChoice? {
        (try? Data(contentsOf: paths.settings)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }?.retroarch
    }

    private func save() {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(retroarch: choice)).write(to: paths.settings, options: .atomic)
    }
}
