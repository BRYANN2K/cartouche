//// The program an installed game starts with, changed after the install. The choices come from the game's own folder,
//// ranked as the install sheet ranks them; a change rewrites the record and the launcher, never the prefix.

import Foundation
import InstallerKit

enum GameExecutable {

    struct Choice: Sendable, Equatable, Hashable {
        let path: String
        // Relative to the game's folder, as the menu shows it.
        let name: String
        let isLauncher: Bool
    }

    struct Options: Sendable, Equatable {
        let folder: URL
        let choices: [Choice]
    }

    struct Change: Sendable {
        let record: InstalledGame
        // What the new program links against and the prefix does not have yet.
        let runtimes: [RuntimeStep]
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    typealias Winetricks = @Sendable (_ verbs: [String], _ prefix: URL, _ wine: WineRunner, _ log: URL) async throws -> InstallRun

    // The folder the picker is limited to: where the game was imported from, else the one the install made.
    static func folder(of record: InstalledGame) -> URL {
        (record.gameFolder ?? record.inferredGameFolder).map { URL(filePath: $0) }
            ?? record.gameRoot
    }

    // The install sheet's ranking: game program first, launchers marked; redistributables, anti-cheat setups and
    // uninstallers are left out. It walks the folder, so it never runs on the main actor.
    static func options(for record: InstalledGame) -> Options {
        let folder = Self.folder(of: record)
        let scan: ExeDetector.Scan
        if record.gameFolder != nil || record.inferredGameFolder != nil {
            scan = ExeDetector.scan(gameFolder: folder)
        } else {
            let primary = GOGInfo.find(in: folder).flatMap { found in
                found.info.primaryExe.map { found.url.deletingLastPathComponent().appending(path: $0) }
            }
            scan = ExeDetector.scan(installFolder: folder, prefix: URL(filePath: record.prefix), primary: primary)
        }
        let base = scan.installFolder.standardizedFileURL.path(percentEncoded: false)
        let choices = scan.candidates.compactMap { candidate -> Choice? in
            let name = relative(candidate.path, to: base)
            if Redistributables.identify(name) != nil || name.lowercased().contains("redist/") { return nil }
            return Choice(path: candidate.path, name: name, isLauncher: candidate.source == .launcher)
        }
        return Options(folder: scan.installFolder, choices: choices)
    }

    // The cached choices with the current program always among them, first when the scan left it out.
    static func listed(_ options: Options?, current: URL?) -> [Choice] {
        let choices = options?.choices ?? []
        guard let current else { return choices }
        let path = current.standardizedFileURL.path(percentEncoded: false)
        guard !choices.contains(where: { $0.path == path }) else { return choices }
        let base = options?.folder.standardizedFileURL.path(percentEncoded: false) ?? ""
        return [Choice(path: path, name: relative(path, to: base), isLauncher: false)] + choices
    }

    static func isCurrent(_ choice: Choice, _ current: URL?) -> Bool {
        current.map { $0.standardizedFileURL.path(percentEncoded: false) == choice.path } ?? false
    }

    // The launcher is written for the game's current runner, graphics and variables; the record keeps everything but
    // the program. Only an .exe inside the game's folder is taken.
    static func change(
        to exe: URL, folder: GameFolder, wine: WineRunner,
        backend: GraphicsBackend?, environment: [String: String], backends: URL
    ) throws -> Change {
        guard var record = InstalledGames.record(in: folder) else {
            throw Failure(errorDescription: String(localized: "Cartouche couldn’t read this install’s record."))
        }
        let path = exe.standardizedFileURL.path(percentEncoded: false)
        let base = Self.folder(of: record).standardizedFileURL.path(percentEncoded: false)
        guard exe.pathExtension.lowercased() == "exe", path.hasPrefix(base.hasSuffix("/") ? base : base + "/"),
              FileManager.default.isReadableFile(atPath: path) else {
            throw Failure(errorDescription: String(localized: "Choose a Windows program inside the game’s folder."))
        }
        let program = URL(filePath: path)
        try GameLauncher.write(exe: program, folder: folder, wine: wine, backend: backend,
                               environment: environment, backends: backends)
        record.exe = path
        try InstalledGames.save(record, in: folder)
        return Change(record: record, runtimes: missing(RuntimeScan.scan(exe: program).steps, installed: record.redistributables))
    }

    static func missing(_ steps: [RuntimeStep], installed: [String]) -> [RuntimeStep] {
        steps.filter { !installed.contains($0.verb) }
    }

    // One verb at a time, each stopped after the timeout as the install does; returns the verbs that installed.
    static func install(
        _ steps: [RuntimeStep], prefix: URL, wine: WineRunner, log: URL,
        timeout: TimeInterval = 300, winetricks: Winetricks
    ) async -> [String] {
        var done: [String] = []
        for step in steps {
            do {
                let run = try await winetricks([step.verb], prefix, wine, log)
                try run.start()
                let killer = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { run.stop() }
                }
                let status = await run.exitStatus()
                killer.cancel()
                if status == 0 && !run.wasStopped {
                    done.append(step.verb)
                } else {
                    AppLog.note("starts with: winetricks \(step.verb) stopped with status \(status); its output is in \(log.path(percentEncoded: false))")
                }
            } catch {
                AppLog.note("starts with: winetricks \(step.verb) failed: \(error.localizedDescription)")
            }
        }
        if !steps.isEmpty {
            let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: SetupEnvironment.base)
            _ = await WineServer.wait(server: wine.server, env: env, timeout: 30)
        }
        return done
    }

    private static func relative(_ path: String, to base: String) -> String {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }
}
