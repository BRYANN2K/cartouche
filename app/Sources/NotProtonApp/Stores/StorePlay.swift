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
        var env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base)
        if let backend = setup.backend {
            env["CX_GRAPHICS_BACKEND"] = backend.rawValue
            let crossOver = FileManager.default.fileExists(atPath: wine.root.appending(path: "share/crossover").path(percentEncoded: false))
            if !crossOver, let dlls = dlls(backend, backends: backends) {
                env["WINEDLLPATH"] = dlls.path + ":" + (env["WINEDLLPATH"] ?? "")
                env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + dlls.overrides
            }
        }
        // The game's own variables, already checked by GameSetupResolver, then the store's
        env.merge(setup.environment) { $1 }
        env.merge(launch.environment.filter { !$0.key.hasPrefix("WINE") }) { $1 }
        return env
    }

    // DXMT or DXVK from backends/, only once their files are in place
    static func dlls(_ backend: GraphicsBackend, backends: URL) -> (path: String, overrides: String)? {
        guard backend == .dxmt || backend == .dxvk, BackendInstaller.receipt(for: backend, in: backends) != nil else { return nil }
        let root = BackendInstaller.folder(for: backend, in: backends)
        let folders = BackendInstaller.folders.map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !folders.isEmpty else { return nil }
        let overrides = backend == .dxmt ? "d3d11,dxgi,d3d10core=b" : "d3d9,d3d10core,d3d11,dxgi=b"
        return (folders.map { $0.path(percentEncoded: false) }.joined(separator: ":"), overrides)
    }

    // DXMT's guide puts winemetal.dll in the prefix as well
    static func prepare(_ backend: GraphicsBackend?, prefix: URL, backends: URL = BackendInstaller.folder) {
        guard backend == .dxmt, BackendInstaller.receipt(for: .dxmt, in: backends) != nil else { return }
        let source = BackendInstaller.folder(for: .dxmt, in: backends).appending(path: "x86_64-windows/winemetal.dll")
        let target = prefix.appending(path: "drive_c/windows/system32/winemetal.dll")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)),
              fm.fileExists(atPath: target.deletingLastPathComponent().path(percentEncoded: false)) else { return }
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
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
