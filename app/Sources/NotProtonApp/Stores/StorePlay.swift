// Store games run under Rosetta, as Windows installs do.

import Foundation
import InstallerKit

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
