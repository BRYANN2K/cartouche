// Every source reads only; none can show a macOS permission prompt.

import Foundation
import GameController
import RetroArchKit
import Synchronization

struct FoundSteam: Equatable, Sendable {
    var account: String?
    var games: Int
}

struct FoundRunner: Equatable, Sendable {
    var name: String
    var ready = true
    var version: String? = nil
}

struct FoundController: Equatable, Sendable {
    var name: String
    var battery: Int?
}

struct FoundFolder: Equatable, Sendable, Identifiable {
    var url: URL
    var games: Int
    var consoles: [String: Int]

    var id: String { url.plainPath }
}

struct MacFindings: Equatable, Sendable {
    var steam: FoundSteam?
    var crossOver: [FoundRunner] = []
    var portingToolkit: [FoundRunner] = []
    var controllers: [FoundController] = []
    var folders: [FoundFolder] = []
    var complete = true

    var isEmpty: Bool {
        steam == nil && crossOver.isEmpty && portingToolkit.isEmpty && controllers.isEmpty && folders.isEmpty
    }

    var consoleGames: [String: Int] {
        folders.reduce(into: [:]) { total, folder in
            for (console, n) in folder.consoles { total[console, default: 0] += n }
        }
    }
}

struct MacScan: Sendable {
    var steam: @Sendable () async -> FoundSteam?
    var crossOver: @Sendable () -> [FoundRunner]
    var portingToolkit: @Sendable () -> [FoundRunner]
    var controllers: @Sendable () async -> [FoundController]
    var folders: @Sendable () -> [FoundFolder]

    static let deadline: Duration = .seconds(3)

    func run(deadline: Duration = Self.deadline) async -> MacFindings {
        let running = Mutex<[Task<Void, Never>]>([])
        return await withCheckedContinuation { continuation in
            let gather = Gather(parts: 5, continuation: continuation)
            running.withLock { tasks in
                tasks = [
                    Task.detached { let v = await steam(); gather.add { $0.steam = v } },
                    Task.detached { let v = crossOver(); gather.add { $0.crossOver = v } },
                    Task.detached { let v = portingToolkit(); gather.add { $0.portingToolkit = v } },
                    Task.detached { let v = await controllers(); gather.add { $0.controllers = v } },
                    Task.detached { let v = folders(); gather.add { $0.folders = v } },
                ]
            }
            Task.detached {
                try? await Task.sleep(for: deadline)
                running.withLock { $0.forEach { $0.cancel() } }
                gather.timeUp()
            }
        }
    }

    private final class Gather: Sendable {
        struct State {
            var found = MacFindings()
            var left: Int
            var continuation: CheckedContinuation<MacFindings, Never>?
        }

        let state: Mutex<State>

        init(parts: Int, continuation: CheckedContinuation<MacFindings, Never>) {
            state = Mutex(State(left: parts, continuation: continuation))
        }

        func add(_ change: @Sendable (inout MacFindings) -> Void) {
            let done = state.withLock { s -> (CheckedContinuation<MacFindings, Never>, MacFindings)? in
                guard let continuation = s.continuation else { return nil }
                change(&s.found)
                s.left -= 1
                guard s.left == 0 else { return nil }
                s.continuation = nil
                return (continuation, s.found)
            }
            done?.0.resume(returning: done!.1)
        }

        func timeUp() {
            let done = state.withLock { s -> (CheckedContinuation<MacFindings, Never>, MacFindings)? in
                guard let continuation = s.continuation else { return nil }
                s.continuation = nil
                s.found.complete = false
                return (continuation, s.found)
            }
            done?.0.resume(returning: done!.1)
        }
    }
}

// MARK: Live sources

extension MacScan {
    static var live: MacScan {
        MacScan(
            steam: { steam(SteamLibraryImporter()) },
            crossOver: {
                RunnerRegistry.refresh().installs.map {
                    FoundRunner(name: [$0.name, $0.releaseVersion].compactMap { $0 }.joined(separator: " "))
                }
            },
            portingToolkit: { portingToolkit() },
            controllers: { await liveControllers() },
            folders: { GameFolderScan(home: SupportPaths.home).run() })
    }

    static func steam(_ importer: SteamLibraryImporter) -> FoundSteam? {
        let library = importer.load()
        guard library.presence != .notInstalled else { return nil }
        return FoundSteam(account: library.account?.accountName, games: library.games.count)
    }

    // Mounted volumes are left out: reading an external disk can show a macOS prompt
    static func portingToolkit(runners: URL = SupportPaths.runners) -> [FoundRunner] {
        var search = PortingToolkitSource.Search.standard
        search.volumes = URL(filePath: "/var/empty", directoryHint: .isDirectory)
        let found = PortingToolkitSource.runners(found: PortingToolkitSource.discover(search), runners: runners)
        var seen: Set<String> = []
        return found.compactMap { runner in
            seen.insert(runner.displayVersion).inserted
                ? FoundRunner(name: "\(Runner.Kind.portingToolkit.name) \(runner.displayVersion)", ready: runner.state == .ready,
                              version: runner.displayVersion) : nil
        }
    }

    @MainActor
    static func liveControllers() async -> [FoundController] {
        var list = GCController.controllers()
        if list.isEmpty {
            try? await Task.sleep(for: .milliseconds(800))
            list = GCController.controllers()
        }
        return list.map { controller in
            let level = controller.battery.map { Int(($0.batteryLevel * 100).rounded()) }
            return FoundController(
                name: controller.vendorName ?? controller.productCategory,
                battery: controller.battery?.batteryState == .unknown ? nil : level)
        }
    }
}

// Only these folder names are looked at - never Documents, Desktop or Downloads, which macOS protects - and nothing leading to another disk.
struct GameFolderScan: Sendable {
    let home: URL
    var candidates = ["Games/ROMs", "Games/roms", "ROMs", "roms", "Emulation/roms", "Emulation", "RetroArch/roms", "Games"]
    var maxEntries = 20_000
    var maxDepth = 4

    static let extensions: [String: String] = [
        "nes": "nes", "sfc": "snes", "smc": "snes", "n64": "n64", "z64": "n64", "v64": "n64",
        "gb": "gb", "gbc": "gbc", "gba": "gba", "nds": "nds",
        "md": "genesis", "gen": "genesis", "smd": "genesis", "sms": "mastersystem", "gg": "gamegear",
        "pce": "pce", "cue": "ps1", "chd": "ps1", "pbp": "ps1", "a26": "atari2600",
    ]

    static let protected = ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music"]

    func run() -> [FoundFolder] {
        let fm = FileManager.default
        var offered: [FoundFolder] = []
        var seen: Set<String> = []
        for name in candidates {
            let folder = home.appending(path: name, directoryHint: .isDirectory)
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue
            else { continue }
            let real = Self.resolved(folder)
            guard isSafe(real), !ScanFence.blocks(root: folder), seen.insert(real.lowercased()).inserted else { continue }
            let counts = count(in: URL(filePath: real, directoryHint: .isDirectory), skipping: offered.map { Self.resolved($0.url) })
            let total = counts.values.reduce(0, +)
            if total > 0 {
                offered.append(FoundFolder(url: folder, games: total, consoles: counts))
            }
        }
        return offered
    }

    static func resolved(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // Inside the home folder, outside the folders macOS protects
    private func isSafe(_ path: String) -> Bool {
        let homePath = Self.resolved(home)
        guard path.hasPrefix(homePath + "/") else { return false }
        let first = path.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return !Self.protected.contains(first)
    }

    private func count(in folder: URL, skipping: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        // Symbolic links are not followed, so nothing outside the folder is read
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return counts }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > maxEntries || Task.isCancelled { break }
            if walker.level > maxDepth { walker.skipDescendants() }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let path = Self.resolved(url)
                if ScanFence.blocks(url) || skipping.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    walker.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            // The extension alone never counts: a header-less .gb is test data,
            // not a game.
            if let console = Self.extensions[ext], CartHeader.plausible(url, ext: ext) {
                counts[console, default: 0] += 1
            }
        }
        return counts
    }
}

extension FoundFolder {
    func shortPath(home: URL = SupportPaths.home) -> String {
        let path = url.plainPath
        let homePath = home.plainPath
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    var consoleNames: [String] {
        consoles.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { ConsoleCatalog.console($0.key)?.name }
    }
}
