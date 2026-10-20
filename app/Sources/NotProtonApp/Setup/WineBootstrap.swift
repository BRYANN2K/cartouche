
import Foundation
import InstallerKit

enum WineBootstrap {

    // The wineboot --init run for a prefix that does not exist yet; nil when it does.
    static func createRun(wine: WineRunner, prefix: URL, base: [String: String], log: URL? = nil) throws -> InstallRun? {
        guard !FileManager.default.fileExists(atPath: prefix.appending(path: "system.reg").path(percentEncoded: false)) else { return nil }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return InstallRun(WineInstall.createPrefix(runner: wine, prefix: prefix, base: base), output: log)
    }
}

enum WineServer {

    // `wineserver -w` returns once every prefix process has exited; after `timeout`, `-k` ends the session so a launcher
    // or crash handler cannot keep it alive forever. True when the wait timed out.
    @discardableResult
    static func wait(server: URL, env: [String: String], timeout: TimeInterval) async -> Bool {
        let waiter = InstallRun(InstallLaunch(executable: server.path(percentEncoded: false), arguments: ["-w"], environment: env))
        guard (try? waiter.start()) != nil else { return false }
        let done = Task { await waiter.exitStatus() }
        let killer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled {
                waiter.stop()
                await kill(server: server, env: env)
            }
        }
        _ = await done.value
        killer.cancel()
        return waiter.wasStopped
    }

    // `wineserver -k` ends the session: the game and anything it left running.
    static func kill(server: URL, env: [String: String]) async {
        let kill = InstallRun(InstallLaunch(executable: server.path(percentEncoded: false), arguments: ["-k"], environment: env))
        guard (try? kill.start()) != nil else { return }
        _ = await kill.exitStatus()
    }
}
