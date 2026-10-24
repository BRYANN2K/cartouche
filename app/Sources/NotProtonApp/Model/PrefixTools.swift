
import AppKit
import Foundation
import InstallerKit
import UniformTypeIdentifiers

enum WineTool: String, CaseIterable, Sendable {
    case winecfg
    case regedit
    case taskmgr

    var label: String {
        switch self {
        case .winecfg: String(localized: "Wine Configuration")
        case .regedit: String(localized: "Registry Editor")
        case .taskmgr: String(localized: "Task Manager")
        }
    }
}

enum PrefixLog: CaseIterable, Sendable {
    case launch
    case wine
    case game
    case crash

    var label: String {
        switch self {
        case .launch: String(localized: "Launch Log")
        case .wine: String(localized: "Wine Log")
        case .game: String(localized: "Game Log")
        case .crash: String(localized: "Crash Report")
        }
    }

    func url(for prefix: WinePrefix, launchers: URL = SupportPaths.launchers) -> URL {
        switch self {
        case .launch: prefix.root.appending(path: "cartouche-run.log")
        case .wine: Self.latestWineLog(for: prefix) ?? launchers.appending(path: prefix.appID).appending(path: "cartouche-wine.log")
        case .game: prefix.root.appending(path: CrashLog.gameLog)
        case .crash: CrashLog.latest(in: prefix.root) ?? prefix.root.appending(path: "\(CrashLog.namePrefix)none.log")
        }
    }

    private static func latestWineLog(for prefix: WinePrefix) -> URL? {
        let root = prefix.root.appending(path: "cartouche-logs")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> (URL, Date)? in
            let file = folder.appending(path: "wine.log")
            guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (file, date)
        }.max { $0.1 < $1.1 }?.0
    }

    // Steam's run script writes the launch and Wine logs; a game Cartouche runs writes its own.
    static func cases(for prefix: WinePrefix) -> [PrefixLog] {
        prefix.source == .steam ? allCases : [.game, .crash]
    }

    // The log the prefix wrote last, a crash report included; nil before any was written.
    static func latest(for prefix: WinePrefix, launchers: URL = SupportPaths.launchers) -> URL? {
        cases(for: prefix).compactMap { log -> (URL, Date)? in
            let url = log.url(for: prefix, launchers: launchers)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (url, modified)
        }
        .max { $0.1 < $1.1 }?.0
    }
}

// The Wine a prefix opens tools with: its loader, server and the environment that points both at it.
struct PrefixWine: Sendable {
    let loader: URL
    let server: URL
    let environment: [String: String]
}

// What compat_run.sh writes to cartouche-build when a tool first runs a prefix.
struct PrefixBuildRecord: Sendable, Equatable {
    let build: String
    let display: String?
}

enum PrefixTools {

    static let buildRecordName = "cartouche-build"

    static func buildRecord(of prefix: WinePrefix) -> PrefixBuildRecord? {
        let file = prefix.root.appending(path: buildRecordName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let build = lines.first, !build.isEmpty else { return nil }
        let display = lines.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        return PrefixBuildRecord(build: build, display: display)
    }

    static func lastBuild(of prefix: WinePrefix, runners: URL = SupportPaths.runners) -> PrefixBuildRecord? {
        if let record = buildRecord(of: prefix) { return record }
        let file = prefix.pfx.appending(path: ".update-timestamp")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let field = text.split(whereSeparator: \.isWhitespace).first,
              let updated = Int(field)
        else { return nil }
        for build in RunnerRegistry.clonedBuilds(in: runners) {
            let inf = SupportPaths.clonedRoot(forBuild: build, runners: runners)
                .appending(path: "share/wine/wine.inf")
            let modified = (try? FileManager.default.attributesOfItem(
                atPath: inf.path(percentEncoded: false))[.modificationDate]) as? Date
            if let modified, Int(modified.timeIntervalSince1970) == updated {
                return PrefixBuildRecord(build: build, display: nil)
            }
        }
        return PrefixBuildRecord(build: "", display: String(localized: "another version of CrossOver"))
    }

    static func writeBuildRecord(_ tool: InstalledTool, for prefix: WinePrefix) throws {
        let file = prefix.root.appending(path: buildRecordName)
        try atomicReplace(file, with: Data("\(tool.build)\n\(tool.display)\n".utf8), step: String(localized: "Record prefix build"))
    }

    static func tool(
        for prefix: WinePrefix, among tools: [InstalledTool] = RunnerRegistry.tools(),
        runners: URL = SupportPaths.runners
    ) -> InstalledTool? {
        let arch = PrefixStore.arch(of: prefix)
        func byArch(_ candidates: [InstalledTool]) -> InstalledTool? {
            guard let arch else { return candidates.first }
            return candidates.first { $0.tool.prefixArch == arch }
        }
        guard let record = lastBuild(of: prefix, runners: runners) else { return byArch(tools) }
        let served = tools.filter { $0.build == record.build }
        if let named = served.first(where: { $0.display == record.display }),
           arch == nil || named.tool.prefixArch == arch {
            return named
        }
        return byArch(served)
    }

    static func resolvedTool(
        step: String, for prefix: WinePrefix, among tools: [InstalledTool] = RunnerRegistry.tools()
    ) throws -> InstalledTool {
        if let found = tool(for: prefix, among: tools) { return found }
        if let record = lastBuild(of: prefix) {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) was last run by \(record.display ?? "build \(record.build)"), which is no longer set up. Rebuild the prefix first.")
            )
        }
        throw StepFailure(step: step, detail: String(localized: "No compatibility tool is set up."))
    }

    static func syncBackend(prefix: WinePrefix) -> String {
        let marker = prefix.root.appending(path: "cartouche-msync")
        let recorded = try? String(contentsOf: marker, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "1" : "0"
    }

    static func environment(
        prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) -> [String: String] {
        let root = runner.path(percentEncoded: false)
        var environment = ProcessInfo.processInfo.environment
        environment["CX_ROOT"] = root
        environment["CX_HOME"] = SupportPaths.applicationSupport
            .appending(path: "CrossOver").path(percentEncoded: false)
        let wine = layout(runner: runner, flavor: flavor)
        environment["WINELOADER"] = wine.loader.path(percentEncoded: false)
        environment["WINESERVER"] = wine.server.path(percentEncoded: false)
        environment["WINEDLLPATH"] = "\(root)/lib/wine/x86_64-windows:"
            + wine.unixDir.path(percentEncoded: false)
        environment["WINEPREFIX"] = prefix.pfx.path(percentEncoded: false)
        environment["WINEMSYNC"] = syncBackend(prefix: prefix)
        environment["PATH"] = "\(root)/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    static func loader(runner: URL, flavor: CompatTool.Flavor = .fex) -> URL {
        layout(runner: runner, flavor: flavor).loader
    }

    struct WineLayout {
        let loader: URL
        let server: URL
        let unixDir: URL
    }

    static func layout(runner: URL, flavor: CompatTool.Flavor = .fex) -> WineLayout {
        let fm = FileManager.default
        let bin = runner.appending(path: "bin")
        func executable(_ url: URL) -> Bool {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false))
        }

        let arm = runner.appending(path: "lib/wine/aarch64-unix")
        let armLoader = arm.appending(path: "wine.app/Contents/MacOS/wine")
        let armServer = bin.appending(path: "wineserver-arm64")
        if flavor == .fex, executable(armLoader), executable(armServer) {
            return WineLayout(loader: armLoader, server: armServer, unixDir: arm)
        }

        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        let server = bin.appending(path: "wineserver")
        return WineLayout(
            loader: unix.appending(path: "wine"),
            server: executable(server) ? server : bin.appending(path: "wineserver-x86"),
            unixDir: unix
        )
    }

    private static func readyLoader(
        step: String, prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor
    ) throws -> URL {
        try readyLoader(step: step, prefix: prefix, loader: loader(runner: runner, flavor: flavor))
    }

    private static func readyLoader(step: String, prefix: WinePrefix, loader: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "No compatibility tool at \(loader.path(percentEncoded: false)). Use Set Up Compatibility Tool first.")
            )
        }
        guard FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) has no prefix at \(prefix.pfx.path(percentEncoded: false)).")
            )
        }
        return loader
    }

    // Steam's prefixes run on the tool their build record names; an installer game's on what
    // its own launcher exports. A store game's Wine is its setup's, which only the library knows.
    static func wine(for prefix: WinePrefix, step: String) throws -> PrefixWine {
        switch prefix.source {
        case .steam:
            let chosen = try resolvedTool(step: step, for: prefix)
            return try wine(
                for: prefix, runner: SupportPaths.clonedRoot(forBuild: chosen.build),
                flavor: chosen.tool.flavor, step: step)
        case .installer:
            guard let found = launcherWine(of: prefix) else {
                throw StepFailure(step: step, detail: String(localized: "Cartouche couldn’t find \(prefix.title)’s launcher."))
            }
            _ = try readyLoader(step: step, prefix: prefix, loader: found.loader)
            return found
        case .store:
            throw StepFailure(
                step: step,
                detail: String(localized: "Cartouche can’t open Wine tools for \(prefix.title) here: its Wine comes from the game’s setup in the library."))
        }
    }

    static func wine(
        for prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex, step: String
    ) throws -> PrefixWine {
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner, flavor: flavor)
        return PrefixWine(
            loader: loader, server: layout(runner: runner, flavor: flavor).server,
            environment: environment(prefix: prefix, runner: runner, flavor: flavor))
    }

    // A store game's Wine: the runner its setup resolves to, with the environment its launch starts from.
    static func wine(
        for prefix: WinePrefix, runner: WineRunner, base: [String: String] = SetupEnvironment.base, step: String
    ) throws -> PrefixWine {
        let loader = try readyLoader(step: step, prefix: prefix, loader: runner.loader)
        return PrefixWine(
            loader: loader, server: runner.server,
            environment: WineInstall.environment(runner: runner, prefix: prefix.pfx, inputs: nil, base: base))
    }

    // The Wine variables GameLauncher wrote into the game's launch script, over the app's
    // environment as Steam's tools get it, and the runner's bin first on PATH.
    static func launcherWine(of prefix: WinePrefix) -> PrefixWine? {
        let script = prefix.root.appending(path: "launch")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        let exports = GameLauncher.exports(in: text)
        guard let loader = exports["WINELOADER"], let server = exports["WINESERVER"] else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment.merge(exports) { $1 }
        environment["WINEPREFIX"] = prefix.pfx.path(percentEncoded: false)
        if let root = exports["CX_ROOT"] {
            environment["PATH"] = "\(root)/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        }
        return PrefixWine(loader: URL(filePath: loader), server: URL(filePath: server), environment: environment)
    }

    static func launch(_ tool: WineTool, in prefix: WinePrefix) throws {
        try launch(tool, with: wine(for: prefix, step: String(localized: "Open \(tool.label)")))
    }

    static func launch(
        _ tool: WineTool, in prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) throws {
        try launch(
            tool, with: wine(for: prefix, runner: runner, flavor: flavor, step: String(localized: "Open \(tool.label)")))
    }

    static func launch(_ tool: WineTool, with wine: PrefixWine) throws {
        try Shell.detach(wine.loader.path(percentEncoded: false), [tool.rawValue], environment: wine.environment)
    }

    static func run(_ executable: URL, in prefix: WinePrefix) throws {
        let step = String(localized: "Run \(executable.lastPathComponent)")
        try run(executable, with: wine(for: prefix, step: step), step: step)
    }

    static func run(
        _ executable: URL,
        in prefix: WinePrefix,
        runner: URL,
        flavor: CompatTool.Flavor = .fex
    ) throws {
        let step = String(localized: "Run \(executable.lastPathComponent)")
        try run(executable, with: wine(for: prefix, runner: runner, flavor: flavor, step: step), step: step)
    }

    static func run(_ executable: URL, with wine: PrefixWine, step: String) throws {
        guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: String(localized: "No file at \(executable.path(percentEncoded: false))."))
        }
        guard let arguments = arguments(for: executable) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(executable.lastPathComponent) is not a Windows program. Pick an exe, msi, bat or cmd file.")
            )
        }

        try Shell.detach(
            wine.loader.path(percentEncoded: false),
            arguments,
            environment: wine.environment,
            currentDirectory: executable.deletingLastPathComponent()
        )
    }

    // Winetricks is LGPL, so it is downloaded rather than shipped.
    static let winetricksRelease = "20260125"
    static let winetricksSHA256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
    static let winetricksLogName = "winetricks.log"

    // Wine truncates vc_redist's 1638 (newer runtime installed) to 102; Winetricks only accepts 236
    static let winetricksWine = #"""
        #!/bin/sh
        "$CARTOUCHE_WINE" "$@"
        status=$?
        case "$status:${1##*[\\/]}" in
          102:[Vv][Cc]*[Rr][Ee][Dd][Ii][Ss][Tt]*.[Ee][Xx][Ee]) exit 236 ;;
        esac
        exit "$status"

        """#

    static func winetricksVerbs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func winetricks(_ verbs: [String], in prefix: WinePrefix) async throws -> URL {
        try await winetricks(verbs, in: prefix, wine: wine(for: prefix, step: String(localized: "Run Winetricks")))
    }

    static func winetricks(_ verbs: [String], in prefix: WinePrefix, wine resolved: PrefixWine) async throws -> URL {
        let step = String(localized: "Run Winetricks")
        let script = try await PinnedDownload.obtain(
            file: "winetricks",
            sha256: winetricksSHA256,
            bases: [QAEnvironment.url(URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(winetricksRelease)/src")!)],
            into: SupportPaths.winetricksDownloads,
            step: step,
            from: "GitHub"
        )
        // Winetricks can run for minutes; the wait never happens on the caller's actor.
        return try await Task.detached {
            try winetricks(verbs, in: prefix, script: script) { _ in resolved }
        }.value
    }

    static func winetricks(
        _ verbs: [String], in prefix: WinePrefix, script: URL, runner: URL,
        flavor: CompatTool.Flavor = .fex
    ) throws -> URL {
        try winetricks(verbs, in: prefix, script: script) { step in
            try wine(for: prefix, runner: runner, flavor: flavor, step: step)
        }
    }

    // The Wine is resolved once the prefix is claimed, so a missing loader never hides a running game.
    private static func winetricks(
        _ verbs: [String], in prefix: WinePrefix, script: URL, resolve: (String) throws -> PrefixWine
    ) throws -> URL {
        let step = String(localized: "Run Winetricks")
        guard !verbs.isEmpty else {
            throw StepFailure(step: step, detail: String(localized: "Enter at least one verb, like vcrun2022."))
        }
        if let refused = refusedVerb(verbs) {
            throw StepFailure(step: step, detail: String(localized: "Cartouche does not run \(refused) with Winetricks."))
        }
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        defer { claim.release() }
        let wine = try resolve(step)
        let loader = wine.loader
        let wrapper = script.deletingLastPathComponent().appending(path: "cartouche-wine")
        do {
            try Data(winetricksWine.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path(percentEncoded: false))
        } catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }

        // cabextract comes from the runner's bin, which the Wine's environment puts on PATH.
        var environment = wine.environment
        environment["WINE"] = wrapper.path(percentEncoded: false)
        environment["CARTOUCHE_WINE"] = loader.path(percentEncoded: false)
        // Winetricks reads the architecture from WINE_BIN, which would otherwise be the wrapper.
        environment["WINE_BIN"] = loader.path(percentEncoded: false)

        let log = prefix.root.appending(path: winetricksLogName)
        let status = try Shell.logged(
            "/bin/sh", [script.path(percentEncoded: false), "-q"] + verbs,
            environment: environment, to: log
        )
        _ = try? Shell.run(wine.server.path(percentEncoded: false), ["-w"], environment: environment)
        guard status == 0 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Winetricks stopped with status \(status). Its output is in \(log.path(percentEncoded: false)).")
            )
        }
        return log
    }

    // Under -q annihilate wipes the prefix and its saves without asking, prefix= switches prefix, --self-update
    // changes winetricks itself. Agents and the prefix sheet share this filter.
    static func refusedVerb(_ verbs: [String]) -> String? {
        verbs.first { $0 == "annihilate" || $0.hasPrefix("prefix=") || $0.hasPrefix("-") }
    }

    static func arguments(for executable: URL) -> [String]? {
        let path = executable.path(percentEncoded: false)
        switch executable.pathExtension.lowercased() {
        case "exe", "bat", "cmd": return [path]
        case "msi": return ["msiexec", "/i", path]
        default: return nil
        }
    }

    static var runnableTypes: [UTType] {
        ["exe", "msi", "bat", "cmd"].compactMap { UTType(filenameExtension: $0) }
    }

    // The open panel for Run Program…, starting in the game's install folder or the prefix's C: drive.
    @MainActor static func chooseProgram(for prefix: WinePrefix) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = runnableTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = String(localized: "Run")
        panel.message = String(localized: "Choose a Windows program to run in \(prefix.title).")
        panel.directoryURL = PrefixStore.installDirectory(of: prefix) ?? driveC(of: prefix)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func driveC(of prefix: WinePrefix) -> URL {
        prefix.pfx.appending(path: "drive_c", directoryHint: .isDirectory)
    }

    static func reveal(_ prefix: WinePrefix) {
        NSWorkspace.shared.selectFile(
            prefix.pfx.path(percentEncoded: false),
            inFileViewerRootedAtPath: prefix.root.path(percentEncoded: false)
        )
    }

    static func hasLog(_ log: PrefixLog, for prefix: WinePrefix) -> Bool {
        FileManager.default.fileExists(atPath: log.url(for: prefix).path(percentEncoded: false))
    }

    static func open(_ log: PrefixLog, for prefix: WinePrefix) {
        NSWorkspace.shared.open(log.url(for: prefix))
    }

    static func reveal(at url: URL) {
        NSWorkspace.shared.selectFile(
            url.path(percentEncoded: false),
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    static func deleteBackup(_ backup: URL) throws {
        try WriteRefused.catching(backup.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func delete(_ prefix: WinePrefix) throws {
        guard prefix.canDelete else {
            throw StepFailure(
                step: String(localized: "Delete prefix"),
                detail: String(localized: "\(prefix.title) keeps its game files in its prefix. Remove the game with Uninstall in the library instead.")
            )
        }
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(
                step: String(localized: "Delete prefix"),
                detail: String(localized: "\(prefix.title) is running. Quit the game first.")
            )
        }
        defer { claim.release() }
        let fm = FileManager.default
        // A store game's folder also holds its record and logs: only the prefix goes.
        if prefix.folder != nil {
            try WriteRefused.catching(prefix.pfx) { try fm.removeItem(at: prefix.pfx) }
            return
        }
        try WriteRefused.catching(prefix.root) { () throws -> Void in
            guard !PrefixStore.backups(of: prefix).isEmpty else {
                try fm.removeItem(at: prefix.root)
                return
            }
            // Backups stay listed and restorable; everything else in the entry goes
            for entry in try fm.contentsOfDirectory(at: prefix.root, includingPropertiesForKeys: nil)
            where !entry.lastPathComponent.hasPrefix(PrefixStore.backupPrefix) {
                try fm.removeItem(at: entry)
            }
        }
    }
}
