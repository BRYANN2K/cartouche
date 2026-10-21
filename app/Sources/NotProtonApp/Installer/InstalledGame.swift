
import Foundation
import InstallerKit

struct InstalledGame: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var appID: Int?
    var gogID: String?
    var runnerID: String
    // Nil on records written before setups were changeable: read as wined3d.
    var graphics: String?
    // Version and kind of the runner that last ran the prefix, for the older-Wine warning when the setup is changed.
    var wineVersion: String?
    var wineRunnerKind: String?
    var prefix: String
    var exe: String
    var installedAt: Date
    var installerFolder: String
    var redistributables: [String]
    var steamShortcut = false
    // The folder of a game imported where it is. Cartouche never deletes it.
    var gameFolder: String?
    // The output check's state (ADR 0026): nil on records that predate verification.
    var verification: VerificationRecord?
    // True once the user named the game themselves; re-identification then leaves name alone.
    var userNamed: Bool? = nil

    var exeURL: URL { URL(filePath: exe) }
    var launcher: URL { URL(filePath: prefix).deletingLastPathComponent().appending(path: "launch") }

    var backend: GraphicsBackend { graphics.flatMap(GraphicsBackend.init(rawValue:)) ?? .wined3d }

    // Where the game's files sit: the folder it was imported in, the folder the
    // install made inside the prefix's drive_c/Games, or the exe's own folder.
    var gameRoot: URL {
        if let gameFolder { return URL(filePath: gameFolder) }
        let games = URL(filePath: prefix).appending(path: "drive_c/Games")
        let base = games.standardizedFileURL.path(percentEncoded: false) + "/"
        let path = exeURL.standardizedFileURL.path(percentEncoded: false)
        if path.hasPrefix(base), let first = path.dropFirst(base.count).split(separator: "/").first {
            return games.appending(path: String(first))
        }
        return exeURL.deletingLastPathComponent()
    }

    // A record written before gameFolder existed: its exe outside the prefix and inside
    // the folder it was imported from can only mean the game stayed in place, so removal
    // is titled "Remove from Library…" and never touches the user's files.
    var inferredGameFolder: String? {
        guard gameFolder == nil else { return nil }
        func inside(_ parent: String, _ child: String) -> Bool {
            child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
        }
        guard !inside(prefix, exe), inside(installerFolder, exe) else { return nil }
        return installerFolder
    }
}

enum InstalledGames {

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

    // A shell script with only the Wine variables the game needs, never the app's own environment. The backend and the
    // game's own variables come from the chosen setup, built the same way as store games.
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
        lines += AdvancedPrefixSettings.launcherLines(environment: env, wine: wine)
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
