// A newer build of an installed runner's series, and moving every game from the old build to it.

import Foundation
import InstallerKit

enum RunnerUpdate {

    static let cartoucheFamily = "wine-crossover"

    // wine-crossover-26.3.0-1 is family wine-crossover, version 26.3.0-1; wine-stable-11.0_1 is wine-stable, 11.0_1
    struct Series: Equatable, Sendable {
        let family: String
        let version: String

        init?(id: String) {
            let parts = id.split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.firstIndex(where: { $0.first?.isNumber == true }), first > 0 else { return nil }
            family = parts[..<first].joined(separator: "-")
            version = parts[first...].joined(separator: "-")
        }

        func isOlder(than other: Series) -> Bool {
            family == other.family && version.compare(other.version, options: .numeric) == .orderedAscending
        }
    }

    // "Cartouche Wine 26.3.0-1": the revision tells two builds of one version apart
    static func cartoucheTitle(id: String) -> String? {
        guard let series = Series(id: id), series.family == cartoucheFamily else { return nil }
        return "\(RunnerManifest.Build.cartoucheName) \(series.version)"
    }

    static func latestCartouche(in manifest: RunnerManifest) -> RunnerManifest.Build? {
        manifest.builds.filter { $0.origin == .cartouche && $0.isPinned && $0.kind == Runner.Kind.wineBuild.rawValue }
            .max { a, b in
                guard let first = Series(id: a.id), let second = Series(id: b.id) else { return false }
                return first.isOlder(than: second)
            }
    }

    // The newest pinned build of the same series, newer than the installed one and not installed itself
    static func offer(for id: String, in manifest: RunnerManifest, installed: Set<String>) -> RunnerManifest.Build? {
        guard let series = Series(id: id) else { return nil }
        let origin = manifest.build(id: id)?.origin
        let newer = manifest.builds.compactMap { build -> (RunnerManifest.Build, Series)? in
            guard build.kind == Runner.Kind.wineBuild.rawValue, build.isPinned, !installed.contains(build.id),
                  origin == nil || build.origin == origin,
                  let candidate = Series(id: build.id), series.isOlder(than: candidate) else { return nil }
            return (build, candidate)
        }
        return newer.max { $0.1.isOlder(than: $1.1) }?.0
    }

    // Installed id → the build it can update to
    static func offers(installed: Set<String>, manifest: RunnerManifest) -> [String: RunnerManifest.Build] {
        var out: [String: RunnerManifest.Build] = [:]
        for id in installed {
            if let build = offer(for: id, in: manifest, installed: installed) { out[id] = build }
        }
        return out
    }
}

enum RunnerMigration {

    // An installer game to move, with the setup its launcher is written from
    struct Job: Sendable, Equatable {
        let folder: GameFolder
        let backend: GraphicsBackend?
        let environment: [String: String]
    }

    // What the files held before the move, to put back when a later step fails
    struct Rollback: Sendable {
        var files: [(url: URL, data: Data?)] = []

        func restore() {
            for (url, data) in files.reversed() {
                if let data {
                    try? atomicReplace(url, with: data, step: WineRunnerInstaller.step)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    static let step = String(localized: "Update runner")

    // Each game's launcher and record follow the new build; the first failure puts every file back and throws.
    static func move(_ jobs: [Job], to runner: Runner, runners: URL, backends: URL) throws -> Rollback {
        var rollback = Rollback()
        guard !jobs.isEmpty else { return rollback }
        guard let wine = InstallRunners.wine(for: runner, runners: runners) else {
            throw StepFailure(step: step, detail: String(localized: "\(runner.name) \(runner.displayVersion) can’t start Windows games yet. Choose another runner in the game’s setup."))
        }
        do {
            for job in jobs {
                guard var record = InstalledGames.record(in: job.folder) else { continue }
                for file in [job.folder.launcher, job.folder.record] {
                    rollback.files.append((file, try? Data(contentsOf: file)))
                }
                try GameLauncher.write(exe: record.exeURL, folder: job.folder, wine: wine, backend: job.backend,
                                       environment: job.environment, backends: backends, runners: runners)
                record.runnerID = runner.id
                record.wineVersion = runner.version
                record.wineRunnerKind = runner.kind.rawValue
                try InstalledGames.save(record, in: job.folder)
            }
        } catch {
            rollback.restore()
            throw error
        }
        return rollback
    }

    // Setups naming the old build name the new one; the ids of the games that changed come back.
    static func replacing(_ old: String, with new: String, in choices: LibraryChoices) -> (LibraryChoices, [String]) {
        var out = choices
        var moved: [String] = []
        for (id, setup) in choices.setups where setup.runnerID == old {
            out.setups[id]?.runnerID = new
            moved.append(id)
        }
        return (out, moved.sorted())
    }

    static func replacing(_ old: String, with new: String, in defaults: SetupDefaults) -> SetupDefaults? {
        guard defaults.runnerID == old else { return nil }
        var out = defaults
        out.runnerID = new
        return out
    }
}
