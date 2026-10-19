// Starting a store game: the runner and graphics backend of its setup, its own
// prefix, and the exe the store names, run under Rosetta as Windows installs are.
// The backend is applied as the Steam run script does (compat_run.sh): CrossOver
// gets CX_GRAPHICS_BACKEND and uses its own copy; another Wine gets Cartouche's
// pinned DXMT or DXVK first in WINEDLLPATH, as builtin DLLs.

import Foundation
import InstallerKit

enum StoreGameEnvironment {

    static func make(
        wine: WineRunner, prefix: URL, setup: GameSetup, launch: StoreLaunch,
        backends: URL = BackendInstaller.folder, base: [String: String]
    ) -> [String: String] {
        // Same env builder as every game Cartouche launches (SetupEnvironment)
        var env = SetupEnvironment.make(wine: wine, prefix: prefix, backend: setup.backend,
                                        environment: setup.environment, backends: backends, base: base)
        // The store's own variables last, minus Wine's own which must not be replaced
        env.merge(launch.environment.filter { !$0.key.hasPrefix("WINE") }) { $1 }
        return env
    }

    static func dlls(_ backend: GraphicsBackend, backends: URL) -> (path: String, overrides: String)? {
        SetupEnvironment.dlls(backend, backends: backends)
    }

    // DXMT's guide puts winemetal.dll in the prefix as well
    static func prepare(_ backend: GraphicsBackend?, prefix: URL, backends: URL = BackendInstaller.folder) {
        SetupEnvironment.prepare(backend, prefix: prefix, backends: backends)
    }

    // The command: arch -x86_64 <wine> <exe> <arguments>
    static func command(wine: WineRunner, launch: StoreLaunch, environment: [String: String]) -> ClientCommand {
        ClientCommand(executable: URL(filePath: WineInstall.rosetta[0]),
                      arguments: Array(WineInstall.rosetta.dropFirst()) + [wine.loader.path(percentEncoded: false),
                                                                          launch.executable.path(percentEncoded: false)] + launch.arguments,
                      environment: environment, currentDirectory: launch.workingDirectory)
    }
}

// A program Cartouche started for a game, and its end
final class StoreProcess: @unchecked Sendable {
    private let process = Process()
    private let exited = AsyncStream<Int32>.makeStream()

    init(_ command: ClientCommand, output: URL?) throws {
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        if let directory = command.currentDirectory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        if let output {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        let continuation = exited.continuation
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func wait() async -> Int32 {
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        return status
    }

    func stop() { if process.isRunning { process.terminate() } }
}
