// Starting a store game: the runner and graphics backend of its setup, its own
// prefix, and the exe the store names, run under Rosetta as Windows installs are.

import Foundation
import InstallerKit

// A program Cartouche started for a game, and its end. The process wrapper of
// the installers, with the store's captured log file.
final class StoreProcess: @unchecked Sendable {
    private let run: InstallRun

    init(_ command: ClientCommand, output: URL?) throws {
        if let output {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        run = InstallRun(InstallLaunch(executable: command.executable.path(percentEncoded: false),
                                     arguments: command.arguments, environment: command.environment,
                                     currentDirectory: command.currentDirectory),
                         output: output)
        try run.start()
    }

    var isRunning: Bool { run.isRunning }

    func wait() async -> Int32 { await run.exitStatus() }

    func stop() { run.stop() }
}
