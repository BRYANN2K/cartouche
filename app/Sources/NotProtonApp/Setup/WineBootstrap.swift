
import Foundation
import InstallerKit

// A fresh prefix is made in one explicit phase — "Preparing Windows environment": `wineboot -u`
// runs to completion, then `wineserver -w` waits for its services to settle. Marker files record
// the state, so a registry file or a timestamp is never taken as proof a prefix is ready. One boot
// runs per prefix at a time; every caller asking for it shares that same run.
enum WineBootstrap {

    enum Outcome: Sendable, Equatable {
        case ready
        case failed(String)
        case stopped
    }

    // Written when a boot starts, removed when `wineserver -w` has returned. A leftover one means
    // the boot was interrupted and the prefix is not ready.
    static let bootingMarker = ".cartouche-booting"
    static let readyMarker = ".cartouche-booted"

    static func needsBoot(_ prefix: URL) -> Bool {
        let fm = FileManager.default
        let path = prefix.path(percentEncoded: false)
        if fm.fileExists(atPath: path + "/" + readyMarker) { return false }
        if fm.fileExists(atPath: path + "/" + bootingMarker) { return true }
        // Prefixes made before the markers existed only have their registry to show for it.
        return !fm.fileExists(atPath: path + "/system.reg")
    }

    // One caller's share of a prefix's boot: the same Boot comes back for every `begin` on a prefix
    // that is already preparing.
    final class Boot: @unchecked Sendable {
        let prefix: URL
        let started: Date
        let log: URL?
        let outcome: Task<Outcome, Never>
        // True while this prefix is being prepared; false when it was already ready. `run` is only
        // populated once the task has started the process, so callers gate on this instead.
        let prepares: Bool

        init(prefix: URL, log: URL?, outcome: Task<Outcome, Never>, prepares: Bool = true) {
            self.prefix = prefix
            self.started = Date()
            self.log = log
            self.outcome = outcome
            self.prepares = prepares
        }

        // The live run: the wineboot process, then the wineserver wait — nil once done.
        var run: InstallRun? { WineBootstrap.run(for: prefix) }

        func stop() { WineBootstrap.stop(prefix) }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var inFlight: [String: Boot] = [:]
    private nonisolated(unsafe) static var runs: [String: InstallRun] = [:]

    // standardizedFileURL adds a trailing "/" once the prefix is a real folder, so the key must
    // never keep it: a boot that starts before the folder exists would be invisible afterwards.
    private static func key(for prefix: URL) -> String {
        var key = prefix.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }

    // Starts the prefix's boot or joins the one in flight. `timeout` covers wineboot; `drain` covers
    // the wineserver wait. Both are the app's own limits, independent of any CI boot check.
    @discardableResult
    static func begin(
        wine: WineRunner, prefix: URL, base: [String: String], log: URL? = nil,
        timeout: TimeInterval = 1800, drain: TimeInterval = 300
    ) -> Boot {
        let key = key(for: prefix)
        return lock.withLock {
            if let boot = inFlight[key] { return boot }
            guard needsBoot(prefix) else { return Boot(prefix: prefix, log: log, outcome: Task { .ready }, prepares: false) }
            let fm = FileManager.default
            try? fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            fm.createFile(atPath: key + "/" + bootingMarker, contents: Data())
            let boot = Boot(prefix: prefix, log: log, outcome: Task {
                await finish(wine: wine, prefix: prefix, base: base, log: log,
                             timeout: timeout, drain: drain, key: key)
            })
            inFlight[key] = boot
            return boot
        }
    }

    // Ends the boot early: the live process is stopped and waiters get .stopped.
    static func stop(_ prefix: URL) {
        lock.withLock { runs[key(for: prefix)]?.stop() }
    }

    static func run(for prefix: URL) -> InstallRun? {
        lock.withLock { runs[key(for: prefix)] }
    }

    private final class Flag: @unchecked Sendable { var value = false }

    private static func finish(
        wine: WineRunner, prefix: URL, base: [String: String], log: URL?,
        timeout: TimeInterval, drain: TimeInterval, key: String
    ) async -> Outcome {
        defer {
            lock.withLock {
                inFlight.removeValue(forKey: key)
                runs.removeValue(forKey: key)
            }
        }
        let env = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base)
        let fm = FileManager.default

        let run = InstallRun(WineInstall.createPrefix(runner: wine, prefix: prefix, base: base), output: log)
        lock.withLock { runs[key] = run }
        guard (try? run.start()) != nil else {
            return .failed(String(localized: "Wine could not start."))
        }
        let bootFlag = Flag()
        let killer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            bootFlag.value = true
            run.stop()
            await WineServer.kill(server: wine.server, env: env)
        }
        let status = await run.exitStatus()
        killer.cancel()
        if run.wasStopped {
            if bootFlag.value {
                return .failed(String(localized: "Wine did not finish preparing the prefix in the time allowed."))
            }
            return .stopped
        }
        guard status == 0 else {
            return .failed(String(localized: "wineboot -u ended with status \(status)."))
        }

        // wineboot has returned; wineserver -w waits for the services it left to settle.
        let waiter = InstallRun(InstallLaunch(executable: wine.server.path(percentEncoded: false),
                                              arguments: ["-w"], environment: env))
        lock.withLock { runs[key] = waiter }
        guard (try? waiter.start()) != nil else {
            return .failed(String(localized: "wineserver could not start."))
        }
        let drainFlag = Flag()
        let drainKiller = Task {
            try? await Task.sleep(for: .seconds(drain))
            guard !Task.isCancelled else { return }
            drainFlag.value = true
            waiter.stop()
            await WineServer.kill(server: wine.server, env: env)
        }
        _ = await waiter.exitStatus()
        drainKiller.cancel()
        if waiter.wasStopped {
            if drainFlag.value {
                return .failed(String(localized: "The prefix's services did not settle in the time allowed."))
            }
            return .stopped
        }

        fm.createFile(atPath: key + "/" + readyMarker, contents: Data())
        try? fm.removeItem(atPath: key + "/" + bootingMarker)
        return .ready
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
