// The library record of a game installed from a Windows installer, and the
// launch script Steam's shortcut and the library start it with.

import Foundation
import InstallerKit

struct InstalledGame: Codable, Sendable, Equatable, Identifiable {
    // The folder name under installs/.
    let id: String
    var name: String
    var appID: Int?
    var gogID: String?
    var runnerID: String
    var prefix: String
    var exe: String
    var installedAt: Date
    // Where the installer files were, for the cleanup offer.
    var installerFolder: String
    var redistributables: [String]
    var steamShortcut = false

    var exeURL: URL { URL(filePath: exe) }
    var launcher: URL { URL(filePath: prefix).deletingLastPathComponent().appending(path: "launch") }
}

enum InstalledGames {

    // Every finished install, for the library (P5) to list.
    static func all(in installs: URL = GameFolder.installs) -> [InstalledGame] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: installs, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: GameFolder(root: folder).record)).flatMap { try? decoder.decode(InstalledGame.self, from: $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ game: InstalledGame, in folder: GameFolder) throws {
        try atomicReplace(folder.record, with: try encoder.encode(game), step: String(localized: "Save the game"))
        try? FileManager.default.removeItem(at: folder.attempt)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum GameLauncher {

    // A shell script with only the Wine variables the game needs, never the
    // app's own environment.
    static func script(exe: URL, prefix: URL, wine: WineRunner) -> String {
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: [:])
        var lines = ["#!/bin/sh", "# Starts the game in its own prefix. Written by Cartouche."]
        for key in ["CX_ROOT", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEPREFIX", "WINEDEBUG"] {
            if let value = env[key] { lines.append("export \(key)=\(quote(value))") }
        }
        lines.append("export PATH=\(quote(wine.root.appending(path: "bin").path(percentEncoded: false))):\"$PATH\"")
        lines.append("cd \(quote(exe.deletingLastPathComponent().path(percentEncoded: false))) || exit 1")
        lines.append("exec \(quote(wine.loader.path(percentEncoded: false))) \(quote(exe.path(percentEncoded: false))) \"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(exe: URL, folder: GameFolder, wine: WineRunner) throws {
        let text = script(exe: exe, prefix: folder.prefix, wine: wine)
        try atomicReplace(folder.launcher, with: Data(text.utf8), step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.launcher.path(percentEncoded: false))
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
