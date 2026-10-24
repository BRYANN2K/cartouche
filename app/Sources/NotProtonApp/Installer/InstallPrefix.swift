//// Where a game installed from a Windows installer lives, and which runner installs it. Every game gets its own
//// folder and its own fresh prefix:
//   installs/<slug>/pfx        the Wine prefix, game files in drive_c/Games/<Name>
//   installs/<slug>/game.json  the library record, written when the install is done

import Foundation
import InstallerKit

struct GameFolder: Sendable, Equatable {
    let root: URL

    var prefix: URL { root.appending(path: "pfx") }
    var record: URL { root.appending(path: "game.json") }
    var launcher: URL { root.appending(path: "launch") }
    var wineOutput: URL { root.appending(path: "wine-output.log") }
    // What the game prints while it plays, a crash's backtrace included.
    var gameLog: URL { root.appending(path: CrashLog.gameLog) }
    var attempt: URL { root.appending(path: ".install-attempt") }

    var isFinished: Bool { FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) }

    // Cartouche's own unfinished attempt: the marker, or for attempts older than it a prefix next to logs only an
    // install writes. A folder with a launcher may be a game whose record was lost, so it is never taken.
    var isUnfinishedAttempt: Bool {
        let fm = FileManager.default
        let exists = { (url: URL) in fm.fileExists(atPath: url.path(percentEncoded: false)) }
        guard !isFinished else { return false }
        if exists(attempt) { return true }
        guard exists(prefix), !exists(launcher) else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.contains { Self.attemptLogs.contains($0) || ($0.hasPrefix("unpack-") && $0.hasSuffix(".log")) }
    }

    static let attemptLogs: Set<String> = ["prefix.log", "processes.log", "wine-output.log", "winetricks-unpacker.log"]

    static let installsKey = "installs.location"
    // Games locations used before the current one, kept while games still live there
    static let previousKey = "installs.previous"
    static var defaultInstalls: URL { SupportPaths.support.appending(path: "installs") }
    // Store games under a chosen location; the space keeps the folder apart from every slug
    static let storeGamesName = "Store Games"

    // The games location picked in onboarding or Settings; an external disk is allowed
    static var installs: URL { current(.standard) }

    static func chosen(_ defaults: UserDefaults) -> URL? {
        defaults.string(forKey: installsKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func current(_ defaults: UserDefaults) -> URL { chosen(defaults) ?? defaultInstalls }

    static func previous(_ defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: previousKey) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    // The current location first, then each earlier one once.
    static func roots(current: URL, previous: [URL]) -> [URL] {
        var seen: Set<String> = []
        return ([current] + previous).filter { seen.insert($0.plainPath).inserted }
    }

    // An installer game's own folder; nil for games from anywhere else.
    static func of(_ game: Game, in installs: URL = installs) -> GameFolder? {
        guard game.source == .installer, game.id.hasPrefix("installer:") else { return nil }
        return of(slug: String(game.id.dropFirst("installer:".count)), in: installs)
    }

    // Where the last scan of several locations found the game, else under installs.
    static func of(slug: String, in installs: URL) -> GameFolder {
        GameFolder(root: (located(slug) ?? installs).appending(path: slug))
    }

    // MARK: Locations

    private static let lock = NSLock()
    nonisolated(unsafe) private static var locatedRoots: [String: URL] = [:]

    static func located(_ slug: String) -> URL? {
        lock.withLock { locatedRoots[slug] }
    }

    // Slugs a scan found in another location: a new install never takes them.
    static func located(outside installs: URL) -> Set<String> {
        let path = installs.plainPath
        return lock.withLock { Set(locatedRoots.filter { $0.value.plainPath != path }.keys) }
    }

    // A scan of several locations replaces what earlier scans said about them.
    static func note(scanned roots: [URL], found: [String: URL]) {
        let paths = Set(roots.map(\.plainPath))
        lock.withLock {
            locatedRoots = locatedRoots.filter { !paths.contains($0.value.plainPath) }
            locatedRoots.merge(found) { _, new in new }
        }
    }

    // New installs go to folder; the location they leave stays known while games live there.
    static func choose(_ folder: URL, leaving current: URL, defaults: UserDefaults) {
        let old = current.plainPath, new = folder.plainPath
        var previous = defaults.stringArray(forKey: previousKey) ?? []
        if old != new && !previous.contains(old) { previous.append(old) }
        previous.removeAll { $0 == new }
        defaults.set(previous, forKey: previousKey)
        defaults.set(new, forKey: installsKey)
    }

    static func forget(_ folders: [URL], defaults: UserDefaults) {
        let gone = Set(folders.map(\.plainPath))
        let kept = (defaults.stringArray(forKey: previousKey) ?? []).filter { !gone.contains($0) }
        defaults.set(kept, forKey: previousKey)
    }

    // Earlier locations without a game left. One on a disk that is not mounted is kept for when it is back.
    static func unused(_ previous: [URL]) -> [URL] {
        let fm = FileManager.default
        return previous.filter { root in
            let path = root.plainPath
            guard fm.fileExists(atPath: path) else {
                let parts = path.split(separator: "/")
                let offline = parts.count > 1 && parts[0] == "Volumes" && !fm.fileExists(atPath: "/Volumes/\(parts[1])")
                return !offline
            }
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return !folders.contains { GameFolder(root: $0).isFinished }
        }
    }

    // Off the main actor: the folder is made if needed, then must take a file. Inside the app it never may.
    static func problem(with folder: URL, app: URL = Bundle.main.bundleURL) -> String? {
        let path = realPath(folder), bundle = realPath(app)
        if path == bundle || path.hasPrefix(bundle + "/") {
            return String(localized: "Games can’t be kept inside the Cartouche app. Choose another folder.")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let probe = folder.appending(path: ".cartouche-write-check-\(UUID().uuidString)")
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            return String(localized: "Cartouche can’t write to this folder. Choose another one.")
        }
        return nil
    }

    // Symlinks resolved as far as the path exists, so a folder not made yet compares like one that is.
    static func realPath(_ url: URL) -> String {
        let fm = FileManager.default
        var base = url.standardizedFileURL, rest: [String] = []
        while base.pathComponents.count > 1, !fm.fileExists(atPath: base.path(percentEncoded: false)) {
            rest.insert(base.lastPathComponent, at: 0)
            base = base.deletingLastPathComponent()
        }
        let head = base.resolvingSymlinksInPath().plainPath
        return rest.isEmpty ? head : (head == "/" ? "" : head) + "/" + rest.joined(separator: "/")
    }

    static func slug(_ name: String) -> String {
        let ascii = WinePath.folderName(name).lowercased()
        let words = ascii.split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "game" : words.joined(separator: "-")
    }

    // A finished game is never reused; an unfinished attempt of the same game is cleared so the retry starts from a fresh prefix.
    // A folder another queued job still holds (held, by folder name) is never taken, even unfinished, nor a slug a game
    // in an earlier location already has.
    static func fresh(for name: String, in installs: URL = installs, held: Set<String> = []) throws -> GameFolder {
        let held = Set(held.union(located(outside: installs)).map { $0.lowercased() })
        let fm = FileManager.default
        try fm.createDirectory(at: installs, withIntermediateDirectories: true)
        let base = slug(name)
        var n = 1
        while true {
            let folder = GameFolder(root: installs.appending(path: n == 1 ? base : "\(base)-\(n)"))
            let path = folder.root.path(percentEncoded: false)
            if held.contains(folder.root.lastPathComponent.lowercased()) { n += 1; continue }
            if !fm.fileExists(atPath: path) { break }
            if folder.isUnfinishedAttempt {
                try fm.removeItem(at: folder.root)
                break
            }
            n += 1
        }
        let folder = GameFolder(root: installs.appending(path: n == 1 ? base : "\(base)-\(n)"))
        try fm.createDirectory(at: folder.prefix, withIntermediateDirectories: true)
        fm.createFile(atPath: folder.attempt.path(percentEncoded: false), contents: Data())
        return folder
    }
}

enum InstallRunners {

    // Runners that can install: set up, serving Rosetta, and either offered to Steam (CrossOver) or a ready free Wine
    // build. Cartouche Wine comes first: it is the one that can load D3DMetal and DXMT.
    static func choices(_ registry: RunnerRegistry, manifest: RunnerManifest = .current()) -> [Runner] {
        let all = registry.runners.filter { runner in
            guard runner.flavors.contains(.rosetta) else { return false }
            switch runner.kind {
            case .crossOver: return runner.isOffered
            case .wineBuild: return runner.isInstalled && runner.state == .ready
            case .portingToolkit: return false
            }
        }
        let own = all.filter { $0.kind == .wineBuild && manifest.build(id: $0.id)?.origin == .cartouche }
        return own + all.filter { runner in !own.contains(where: { $0.id == runner.id }) }
    }

    // The runner's Wine, always its x86_64 side: installs run under Rosetta.
    static func wine(for runner: Runner, runners: URL = SupportPaths.runners) -> WineRunner? {
        let fm = FileManager.default
        let executable = { (url: URL) in fm.isExecutableFile(atPath: url.path(percentEncoded: false)) }
        switch runner.kind {
        case .crossOver:
            guard let build = runner.build else { return nil }
            let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
            let layout = PrefixTools.layout(runner: root, flavor: .rosetta)
            guard executable(layout.loader) else { return nil }
            return WineRunner(root: root, loader: layout.loader, server: layout.server, dllPath: dllPath(root, unix: layout.unixDir))
        case .wineBuild:
            let root = WineRunnerInstaller.dir(for: runner.id, runners: runners)
            let unix = root.appending(path: "lib/wine/x86_64-unix")
            // The receipt records the manifest's loader; guesses cover receipts that predate it
            let loaders = [WineRunnerInstaller.receipt(for: runner.id, runners: runners)?.loader]
                .compactMap { $0 }.map { root.appending(path: $0) }
                + [unix.appending(path: "wine"), root.appending(path: "bin/wine"), root.appending(path: "bin/wine64")]
            guard let loader = loaders.first(where: executable) else { return nil }
            return WineRunner(root: root, loader: loader, server: root.appending(path: "bin/wineserver"), dllPath: dllPath(root, unix: unix))
        case .portingToolkit:
            return nil
        }
    }

    private static func dllPath(_ root: URL, unix: URL) -> String {
        root.appending(path: "lib/wine/x86_64-windows").path(percentEncoded: false) + ":" + unix.path(percentEncoded: false)
    }
}
