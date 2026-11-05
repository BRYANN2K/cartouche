// EA app and Ubisoft Connect: each official Windows launcher lives in one dedicated Wine
// prefix under the store's folder, booted like a game's prefix and driven through the
// protocol URIs it registers (uplay://, origin2://). The installer's silent flags are the
// vendors' documented ones — still unverified on a real prefix until the W1 real test.

import Foundation
import InstallerKit

// A Windows program left running in the prefix — the launcher itself.
protocol LauncherProcess: Sendable {
    var isRunning: Bool { get }
    func wait() async -> Int32
    func stop()
}

extension StoreProcess: LauncherProcess {}

// Runs commands inside a launcher prefix; tests record them instead of starting Wine.
protocol LauncherRun: Sendable {
    func run(_ command: ClientCommand) async throws -> ClientOutput
    func start(_ command: ClientCommand) async throws -> any LauncherProcess
    // drained: stderr to a continuously-read pipe, no disk log (B7 — EA).
    func start(_ command: ClientCommand, drained: Bool) async throws -> any LauncherProcess
}

struct ProcessLauncherRun: LauncherRun {
    var log: URL? = nil
    func run(_ command: ClientCommand) async throws -> ClientOutput { try await ClientProcess.run(command) }
    func start(_ command: ClientCommand) async throws -> any LauncherProcess { try StoreProcess(command, output: log) }
    // Drained stderr, no disk log — B7: EA's launcher must really write its trace
    // (a continuous reader) while nothing of it is kept.
    func start(_ command: ClientCommand, drained: Bool) async throws -> any LauncherProcess {
        try StoreProcess(command, output: drained ? nil : log, drain: drained)
    }
}

extension LauncherRun {
    func start(_ command: ClientCommand, drained: Bool) async throws -> any LauncherProcess {
        try await start(command)
    }
}

// The URIs each launcher's protocol handles, and the official store on the web.
enum LauncherLinks {
    static func open(_ store: GameSource) -> String { store == .ea ? "origin2://" : "uplay://" }

    static func launch(_ store: GameSource, id: String) -> String {
        store == .ea ? "origin2://game/launch?offerIds=\(id)" : "uplay://launch/\(id)/0"
    }

    // Install is the launcher's own page: the confirm stays the user's there.
    static func install(_ store: GameSource, id: String) -> String? {
        store == .ea ? "origin2://game/launch?offerIds=\(id)&autoDownload=1" : "uplay://install/\(id)"
    }

    static func uninstall(_ store: GameSource, id: String) -> String? {
        store == .ea ? nil : "uplay://uninstall/\(id)"
    }

    // The game's own page inside the launcher (Ubisoft only).
    static func gamePage(_ store: GameSource, launchID: String) -> String? {
        store == .ea ? nil : "uplay://open/game/\(launchID)"
    }

    // The publisher's web store — the game's page when its slug is known.
    static func storePage(_ store: GameSource, slug: String? = nil) -> URL {
        if store == .ea {
            return URL(string: slug.map { "https://www.ea.com/games/\($0)" } ?? "https://www.ea.com/games")!
        }
        return URL(string: "https://store.ubisoft.com")!
    }
}

// system.reg in a prefix: [Software\\Key\\Sub] sections then "Name"="Value" lines.
// Names come back unescaped and lowercased, keys unescaped — plain Windows paths.
enum WineRegistry {

    static func read(prefix: URL) -> String? {
        guard let data = try? Data(contentsOf: prefix.appending(path: "system.reg")) else { return nil }
        // Wine writes UTF-16; older prefixes and test fixtures may hold UTF-8.
        if data.count > 1, (data[0] == 0xFF && data[1] == 0xFE) || data[1] == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    static func sections(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var name: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                name = unescape(String(line[line.index(after: line.startIndex)..<close]))
            } else if let name, let pair = self.pair(line) {
                out[name, default: [:]][pair.0] = pair.1
            }
        }
        return out
    }

    static func values(_ text: String, in key: String) -> [String: String]? {
        values(in: sections(text), under: key)
    }

    // Same lookup on sections already parsed, so a polling caller does not reparse the file each tick
    static func values(in sections: [String: [String: String]], under key: String) -> [String: String]? {
        sections.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    // Each <key>\<id> section that holds an InstallDir value: id → the Windows path.
    static func installedGames(in text: String, under key: String) -> [String: String] {
        installedGames(in: sections(text), under: key)
    }

    static func installedGames(in sections: [String: [String: String]], under key: String) -> [String: String] {
        var out: [String: String] = [:]
        let prefix = key.uppercased() + "\\"
        for (name, values) in sections where name.count > key.count && name.uppercased().hasPrefix(prefix) {
            guard let dir = values["installdir"] else { continue }
            out[String(name.dropFirst(key.count + 1))] = dir
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        var out = "", it = s.makeIterator()
        while var c = it.next() {
            if c == "\\", let next = it.next() { c = next }
            out.append(c)
        }
        return out
    }

    // "Name"="Value" with Wine's \ escapes, value name lowercased
    private static func pair(_ line: String) -> (String, String)? {
        guard line.hasPrefix("\"") else { return nil }
        var i = line.startIndex
        func quoted() -> String? {
            i = line.index(after: i)
            var out = ""
            while i < line.endIndex {
                if line[i] == "\\" {
                    i = line.index(after: i)
                    guard i < line.endIndex else { return nil }
                    out.append(line[i]); i = line.index(after: i); continue
                }
                if line[i] == "\"" { i = line.index(after: i); return out }
                out.append(line[i]); i = line.index(after: i)
            }
            return nil
        }
        guard let name = quoted(), i < line.endIndex, line[i] == "=" else { return nil }
        i = line.index(after: i)
        guard let value = quoted() else { return nil }
        return (name.lowercased(), value)
    }
}

// What "still working" looks like on disk while a launcher fetches or removes a game.
enum LauncherFolder {

    // Total bytes under the folder, 0 when it does not exist: a growing count means the
    // download is live, an equal count across two polls that it settled.
    static func folderBytes(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return -1 }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// One launcher's dedicated prefix and the three commands it takes: wineboot on first
// use, the vendor installer, then the launcher exe itself (a URI makes it open a page).
struct StoreLauncher: Sendable {
    let store: GameSource
    // stores/<id>/launcher
    let folder: URL
    var wine: @Sendable () async throws -> WineRunner
    // The backend a store game's own launch would pick: the launcher stays the game's
    // parent process, so its environment is what the game inherits (B11).
    var backend: @Sendable () async -> GraphicsBackend? = { nil }
    var backends: URL = BackendInstaller.folder
    var runners: URL = SupportPaths.runners
    // The backend's engine clone, injectable for tests; the real one is GraphicsRunner's.
    var prepareGraphics: @Sendable (WineRunner, GraphicsBackend?, URL, URL) throws -> WineRunner = GraphicsRunner.prepare
    var run: any LauncherRun = ProcessLauncherRun()
    // The prefix's first boot, injectable for tests; the real one is WineBootstrap's.
    var boot: @Sendable (WineRunner, URL, [String: String], URL) async throws -> Void = StoreLauncher.wineBoot
    var base: [String: String] = SetupEnvironment.base

    var prefix: URL { folder.appending(path: "pfx") }
    var log: URL { folder.appending(path: "launcher.log") }

    // Where the vendor installer puts the launcher with its defaults.
    var executable: URL {
        switch store {
        case .ea:
            return prefix.appending(path: "drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe")
        default:
            return prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe")
        }
    }

    var installed: Bool { FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) }

    // The vendors' documented silent flags; unverified under Wine until the real test.
    var installerArguments: [String] {
        switch store {
        // EA's Burn bootstrapper refuses silent switches (W1): it runs bare, and only
        // to seed the Package Cache — the admin-extract in installEA does the rest.
        case .ea: []
        default: ["/S"]
        }
    }

    // Extra environment for the launcher exe itself: EA's Qt needs software raster (W1/B3),
    // and B7's recipe — +wbemprox tracing whose writes are drained by the bounded output
    // pipe — slows the WMI path enough that the survey→FSM race settles to awaitingAuthentication.
    var launchEnvironment: [String: String] {
        store == .ea ? ["QT_QUICK_BACKEND": "software", "QT_OPENGL": "software",
                        "QMLSCENE_DEVICE": "softwarecontext", "WINEDEBUG": "+wbemprox"] : [:]
    }

    // Extra arguments for the launcher exe, forwarded to its CEF browser processes (upc.exe,
    // EACefSubProcess.exe). Their separate GPU process never paints under Wine (B9): EA's sign-in
    // page stayed black. The GPU service stays in-process and off, software compositing.
    var launchArguments: [String] { ["--in-process-gpu", "--disable-gpu"] }

    // Ran before the launcher exe starts — EA's LSX port check lives here.
    var preflight: @Sendable () async throws -> Void = {}

    static func wineBoot(wine: WineRunner, prefix: URL, base: [String: String], log: URL) async throws {
        let boot = WineBootstrap.begin(wine: wine, prefix: prefix, base: base, log: log)
        guard boot.prepares else { return }
        switch await boot.outcome.value {
        case .ready: return
        case .stopped: throw StoreError.failed(String(localized: "Stopped"))
        case .failed(let detail): throw StoreError.failed(detail)
        }
    }

    private func command(_ wine: WineRunner, _ exe: URL, _ arguments: [String], extra: [String: String] = [:], backend: GraphicsBackend? = nil) -> ClientCommand {
        var environment = WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base)
        SetupEnvironment.applyBackend(&environment, backend: backend, wine: wine, backends: backends, runners: runners)
        for (key, value) in extra { environment[key] = value }
        return ClientCommand(executable: URL(filePath: WineInstall.rosetta[0]),
                      arguments: Array(WineInstall.rosetta.dropFirst())
                          + [wine.loader.path(percentEncoded: false), exe.path(percentEncoded: false)] + arguments,
                      environment: environment,
                      currentDirectory: exe.deletingLastPathComponent())
    }

    // A Wine builtin (msiexec, reg, …) instead of a program file.
    private func tool(_ wine: WineRunner, _ name: String, _ arguments: [String]) -> ClientCommand {
        ClientCommand(executable: URL(filePath: WineInstall.rosetta[0]),
                      arguments: Array(WineInstall.rosetta.dropFirst())
                          + [wine.loader.path(percentEncoded: false), name] + arguments,
                      environment: WineInstall.environment(runner: wine, prefix: prefix, inputs: nil, base: base))
    }

    // A unix path as Wine sees it: C:\ inside the prefix, Z:\ outside.
    func windowsPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let drive = prefix.appending(path: "drive_c").path(percentEncoded: false)
        let root = path.hasPrefix(drive + "/") ? "C:" + path.dropFirst(drive.count) : "Z:" + path
        return root.replacingOccurrences(of: "/", with: "\\")
    }

    // The installer run to the end; the launcher exe must exist afterwards.
    func install(from installer: URL) async throws {
        switch store {
        case .ea: try await installEA(from: installer)
        default:
            let wine = try await wine()
            try await boot(wine, prefix, base, log)
            let output = try await run.run(command(wine, installer, installerArguments))
            guard output.succeeded, installed else {
                throw StoreError.failed(String(localized: "The \(store.name) installer did not finish. Open it again to check."))
            }
        }
    }

    // The bootstrapper refuses silent switches; run bare it seeds the Package Cache — and on
    // the shipped runner it really installs, into the versioned EA Desktop\<ver>\EA Desktop
    // (the stable EA Desktop\EA Desktop is a junction Windows creates, Wine does not — B-E2).
    // The admin-extract stays as fallback for the runner where msiexec /a works (W1).
    private func installEA(from installer: URL) async throws {
        let wine = try await wine()
        try await boot(wine, prefix, base, log)
        let isMSI = installer.pathExtension.lowercased() == "msi"
        if !isMSI {
            _ = try? await run.run(command(wine, installer, []))
            // The installer's last act starts the client itself, without our Qt env: a
            // headless EADesktop spins — only the background service is meant to stay.
            _ = try? await run.run(tool(wine, "taskkill", ["/f", "/im", "EADesktop.exe"]))
        }
        var app = Self.find("EADesktop.exe", under: prefix.appending(path: "drive_c/Program Files/Electronic Arts"))
        if app == nil, let msi = isMSI ? installer : Self.cachedMSI(in: prefix) {
            let stage = prefix.appending(path: "drive_c/eaadmin")
            _ = try? await run.run(tool(wine, "msiexec", ["/a", windowsPath(msi), "/qn", "TARGETDIR=C:\\eaadmin"]))
            app = Self.find("EADesktop.exe", under: stage)
        }
        guard let app else {
            throw StoreError.failed(String(localized: "The EA app installer did not finish. Open it again to check."))
        }
        let target = prefix.appending(path: "drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop")
        if app.deletingLastPathComponent() != target {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: app.deletingLastPathComponent(), to: target)
        }
        for arguments in EARegistry.writes(exe: "C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EADesktop.exe") {
            _ = try? await run.run(tool(wine, "reg", arguments))
        }
        guard installed else {
            throw StoreError.failed(String(localized: "The EA app installer did not finish. Open it again to check."))
        }
    }

    // EAapp-*.msi inside the Package Cache the bootstrapper run just seeded.
    static func cachedMSI(in prefix: URL) -> URL? {
        let cache = prefix.appending(path: "drive_c/ProgramData/Package Cache")
        let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("EAapp-"), url.pathExtension.lowercased() == "msi" { return url }
        }
        return nil
    }

    // EA ships a same-named stub under compatibility32/ — only worth keeping when the
    // real exe is absent, never preferred over it.
    static func find(_ name: String, under folder: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var stub: URL?
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name {
                if url.path.contains("/compatibility32/") { stub = stub ?? url; continue }
                return url
            }
        }
        return stub
    }

    // The launcher left running; a URI argument makes it open that page. Its env carries
    // the backend — the launcher stays the game's parent process, so that env is the
    // game's (B11); no game-layer variable rides here, a protected game gets none.
    @discardableResult
    func open(_ uri: String? = nil) async throws -> any LauncherProcess {
        let wine = try await wine()
        guard installed else {
            throw StoreError.failed(String(localized: "Install \(store.name) first."))
        }
        let backend = await backend()
        let prepared = try await Task.detached { [wine, backends, runners] in
            try prepareGraphics(wine, backend, backends, runners)
        }.value
        try await boot(prepared, prefix, base, log)
        SetupEnvironment.prepare(backend, prefix: prefix, backends: backends)
        try await preflight()
        return try await run.start(command(prepared, executable, (uri.map { [$0] } ?? []) + launchArguments, extra: launchEnvironment, backend: backend), drained: store == .ea)
    }

    func registry() -> [String: [String: String]] {
        WineRegistry.read(prefix: prefix).map(WineRegistry.sections) ?? [:]
    }
}

// The registry writes the admin extract skips (W1): the background service, and the
// protocol handlers the real installer would have registered.
enum EARegistry {

    static func writes(exe: String) -> [[String]] {
        let service = #"HKLM\SYSTEM\CurrentControlSet\Services\EABackgroundService"#
        var writes = [
            ["add", service, "/v", "ImagePath", "/t", "REG_EXPAND_SZ", "/d",
             #"C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EABackgroundService.exe"#, "/f"],
            ["add", service, "/v", "DisplayName", "/t", "REG_SZ", "/d", "EA Background Service", "/f"],
            ["add", service, "/v", "Start", "/t", "REG_DWORD", "/d", "0x3", "/f"],
            ["add", service, "/v", "Type", "/t", "REG_DWORD", "/d", "0x10", "/f"],
            ["add", service, "/v", "ObjectName", "/t", "REG_SZ", "/d", "LocalSystem", "/f"],
        ]
        for scheme in ["origin2", "link2ea", "eadesktop"] {
            writes.append(["add", "HKCR\\\(scheme)", "/v", "URL Protocol", "/t", "REG_SZ", "/d", "", "/f"])
            writes.append(["add", "HKCR\\\(scheme)\\shell\\open\\command", "/ve", "/t", "REG_SZ",
                           "/d", "\"\(exe)\" \"%1\"", "/f"])
        }
        return writes
    }
}

// Port 3216 is the LSX port Origin/EA games hard-code to reach the client: when another
// process holds it, EADesktop only shows "Communication error" (W1). Checking before a
// launch names the real blocker instead.
enum EAPreflight {

    static let lsxPort: UInt16 = 3216

    static func checkLSX() async throws {
        if let holder = await holder(of: lsxPort), blocks(holder: holder) {
            throw StoreError.failed(String(localized: "The EA app needs port 3216, already used by \(holder). Quit it and try again."))
        }
    }

    // A launcher already running holds the port itself: only someone else's process is in the way.
    static func blocks(holder: String) -> Bool {
        let name = holder.lowercased()
        return !name.contains("wine") && !name.hasPrefix("ea")
    }

    // The process name holding the port on 127.0.0.1, or nil when it is free.
    static func holder(of port: UInt16) async -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound != 0 else { return nil }
        // Something holds it — lsof names it so the error can say what to quit.
        guard let output = try? await ClientProcess.run(ClientCommand(
                executable: URL(filePath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "c"],
                environment: [:])) else { return "another process" }
        return output.stdout.split(separator: "\n").first(where: { $0.hasPrefix("c") })
            .map { String($0.dropFirst()) } ?? "another process"
    }
}
