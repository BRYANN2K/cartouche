// Where a game installed from a Windows installer lives, and which runner
// installs it. Every game gets its own folder and its own fresh prefix:
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
    // Marks a folder Cartouche made for an install that is not finished yet.
    var attempt: URL { root.appending(path: ".install-attempt") }

    var isFinished: Bool { FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) }

    static var installs: URL { SupportPaths.support.appending(path: "installs") }

    static func slug(_ name: String) -> String {
        let ascii = WinePath.folderName(name).lowercased()
        let words = ascii.split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "game" : words.joined(separator: "-")
    }

    // A finished game is never reused; an unfinished attempt of the same game
    // is cleared so the retry starts from a fresh prefix.
    static func fresh(for name: String, in installs: URL = installs) throws -> GameFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: installs, withIntermediateDirectories: true)
        let base = slug(name)
        var n = 1
        while true {
            let folder = GameFolder(root: installs.appending(path: n == 1 ? base : "\(base)-\(n)"))
            let path = folder.root.path(percentEncoded: false)
            if !fm.fileExists(atPath: path) { break }
            if !folder.isFinished, fm.fileExists(atPath: folder.attempt.path(percentEncoded: false)) {
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

    // Runners that can install: set up, serving Rosetta, and either offered to
    // Steam (CrossOver) or a ready free Wine build.
    static func choices(_ registry: RunnerRegistry) -> [Runner] {
        registry.runners.filter { runner in
            guard runner.flavors.contains(.rosetta) else { return false }
            switch runner.kind {
            case .crossOver: return runner.isOffered
            case .wineBuild: return runner.isInstalled && runner.state == .ready
            case .portingToolkit: return false
            }
        }
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
