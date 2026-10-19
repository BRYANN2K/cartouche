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
    // The graphics backend of the setup applied to the launcher (raw GraphicsBackend).
    // Nil on records written before setups were changeable: read as wined3d.
    var graphics: String?
    // Version and kind of the runner that last ran the prefix, for the
    // older-Wine warning when the setup is changed.
    var wineVersion: String?
    var wineRunnerKind: String?
    var prefix: String
    var exe: String
    var installedAt: Date
    // Where the installer files were, for the cleanup offer.
    var installerFolder: String
    var redistributables: [String]
    var steamShortcut = false

    var exeURL: URL { URL(filePath: exe) }
    var launcher: URL { URL(filePath: prefix).deletingLastPathComponent().appending(path: "launch") }

    // The backend the launcher's setup applies; a plain install is wined3d
    var backend: GraphicsBackend { graphics.flatMap(GraphicsBackend.init(rawValue:)) ?? .wined3d }
}

enum InstalledGames {

    // Every finished install, for the library to list.
    static func all(in installs: URL = GameFolder.installs) -> [InstalledGame] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: installs, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { record(in: GameFolder(root: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func record(in folder: GameFolder) -> InstalledGame? {
        (try? Data(contentsOf: folder.record)).flatMap { try? RecordCoding.decoder.decode(InstalledGame.self, from: $0) }
    }

    static func save(_ game: InstalledGame, in folder: GameFolder) throws {
        try atomicReplace(folder.record, with: try RecordCoding.encoder.encode(game), step: String(localized: "Save the game"))
        try? FileManager.default.removeItem(at: folder.attempt)
    }
}

enum GameLauncher {

    // A shell script with only the Wine variables the game needs, never the
    // app's own environment. The backend and the game's own variables come from
    // the setup the user chose, built the same way as store games.
    static func script(
        exe: URL, prefix: URL, wine: WineRunner,
        backend: GraphicsBackend? = nil, environment: [String: String] = [:],
        backends: URL = BackendInstaller.folder
    ) -> String {
        let env = SetupEnvironment.make(wine: wine, prefix: prefix, backend: backend,
                                        environment: environment, backends: backends, base: [:])
        var lines = ["#!/bin/sh", "# Starts the game in its own prefix. Written by Cartouche."]
        for key in ["CX_ROOT", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEPREFIX", "WINEDEBUG",
                    "CX_GRAPHICS_BACKEND", "WINEDLLOVERRIDES"] + environment.keys.sorted() {
            if let value = env[key] { lines.append("export \(key)=\(quote(value))") }
        }
        lines.append("export PATH=\(quote(wine.root.appending(path: "bin").path(percentEncoded: false))):\"$PATH\"")
        lines += controlsBlock(folder: GameFolder(root: prefix.deletingLastPathComponent()))
        lines.append("cd \(quote(exe.deletingLastPathComponent().path(percentEncoded: false))) || exit 1")
        lines.append("exec \(quote(wine.loader.path(percentEncoded: false))) \(quote(exe.path(percentEncoded: false))) \"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(
        exe: URL, folder: GameFolder, wine: WineRunner,
        backend: GraphicsBackend? = nil, environment: [String: String] = [:],
        backends: URL = BackendInstaller.folder
    ) throws {
        let text = script(exe: exe, prefix: folder.prefix, wine: wine,
                          backend: backend, environment: environment, backends: backends)
        try atomicReplace(folder.launcher, with: Data(text.utf8), step: String(localized: "Write the game's launcher"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.launcher.path(percentEncoded: false))
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
