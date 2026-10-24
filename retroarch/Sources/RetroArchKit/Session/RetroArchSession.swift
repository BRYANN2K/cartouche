import Foundation

public enum RetroArchSessionError: Error, Equatable, Sendable {
    case notRunning
    case alreadyRunning
    case needsMCP
    case toolUnavailable(String)
    case toolFailed(tool: String, reason: String)
    case exitedEarly(status: Int32?)
    case unexpectedReply(String)
}

public struct RetroArchLaunch: Sendable {

    // The retroarch.cfg RetroArch loads before cartouche.cfg
    public enum BaseConfig: Sendable, Equatable {
        // RetroArch still writes its own file at times (e.g. after unpacking assets), whatever config_save_on_exit says.
        case cartouche
        case retroarchDefault
        case file(URL)
    }

    public var executable: URL
    public var config: AppendConfig
    public var baseConfig: BaseConfig
    // Builds without the MCP server get -L <core> <file> and no pipe
    public var mcp: Bool
    public var environment: [String: String]?
    public var verbose = false
    // Netplay starts with the content RetroArch loads next
    public var netplay: NetplayRole?

    public init(executable: URL, config: AppendConfig, baseConfig: BaseConfig = .cartouche, mcp: Bool = true) {
        self.executable = Self.binary(executable)
        self.config = config
        self.baseConfig = baseConfig
        self.mcp = mcp
    }

    public static func binary(_ url: URL) -> URL {
        url.pathExtension == "app" ? url.appending(path: "Contents/MacOS/RetroArch") : url
    }

    var baseConfigFile: URL? {
        switch baseConfig {
        case .cartouche: config.paths.baseConfig
        case .retroarchDefault: nil
        case .file(let url): url
        }
    }

    // RetroArch skips --appendconfig too when the -c file is not there, so Cartouche's own one is made first.
    func prepare() throws {
        try config.write()
        if baseConfig == .cartouche,
           !FileManager.default.fileExists(atPath: config.paths.baseConfig.path(percentEncoded: false))
        {
            try Data("# RetroArch's settings for the RetroArch included with Cartouche\n".utf8)
                .write(to: config.paths.baseConfig)
        }
    }

    public func arguments(core: URL? = nil, content: URL? = nil) -> [String] {
        var arguments: [String] = []
        if mcp { arguments.append("--mcp-stdio") }
        if verbose { arguments.append("-v") }
        if let file = baseConfigFile { arguments += ["-c", file.path(percentEncoded: false)] }
        arguments += ["--appendconfig", config.paths.appendConfig.path(percentEncoded: false)]
        switch netplay {
        case .host(let port, _):
            arguments += ["--host", "--port", String(port)]
        case .join(let target):
            arguments += ["--connect", target.address, "--port", String(target.port)]
            if let session = target.session { arguments += ["--mitm-session", session] }
        case nil:
            break
        }
        if let core, let content {
            arguments += ["-L", core.path(percentEncoded: false), content.path(percentEncoded: false)]
        }
        return arguments
    }
}

public struct StopReport: Sendable, Equatable {
    public enum Way: Sendable, Equatable {
        case quit, terminated, killed, notRunning
    }

    public var way: Way
    public var duration: Duration

    public init(way: Way, duration: Duration) {
        self.way = way
        self.duration = duration
    }
}

// One running RetroArch, driven over its MCP pipe; nothing else talks to it.
public actor RetroArchSession {

    public let launch: RetroArchLaunch
    public private(set) var tools = ToolMap([])

    private var child: ChildProcess?
    private var client: MCPClient?
    private var reader: Task<Void, Never>?

    public init(launch: RetroArchLaunch) {
        self.launch = launch
    }

    public var processIdentifier: Int32? { child?.identifier }

    public var isRunning: Bool { child != nil && child?.exitStatus == nil }

    public var stderrLog: URL { launch.config.paths.logs.appending(path: "retroarch.log") }

    public func start(timeout: Duration = .seconds(15)) async throws {
        guard launch.mcp else { throw RetroArchSessionError.needsMCP }
        guard child == nil else { throw RetroArchSessionError.alreadyRunning }
        try launch.prepare()

        let (lines, feed) = AsyncStream.makeStream(of: Data.self)
        let child = try ChildProcess(
            executable: launch.executable, arguments: launch.arguments(),
            environment: launch.environment, stderr: stderrLog, pipes: true
        ) { line in
            if let line { feed.yield(line) } else { feed.finish() }
        }
        let client = MCPClient(send: { try child.write($0) })
        self.child = child
        self.client = client
        reader = Task {
            for await line in lines { await client.receive(line) }
            await client.close()
        }

        do {
            _ = try await client.initialize(client: "Cartouche", version: "1")
            tools = ToolMap(try await client.listTools())
        } catch {
            _ = await stop(within: .seconds(1))
            if case MCPClientError.closed = error { throw RetroArchSessionError.exitedEarly(status: child.exitStatus) }
            throw error
        }
    }

    // Without MCP: the game goes on the command line; UDP commands, when on, are the way to ask and to quit.
    public func start(core: URL, content: URL) throws {
        guard child == nil else { throw RetroArchSessionError.alreadyRunning }
        try launch.prepare()
        child = try ChildProcess(
            executable: launch.executable, arguments: launch.arguments(core: core, content: content),
            environment: launch.environment, stderr: stderrLog, pipes: false, onLine: { _ in })
    }

    @discardableResult
    public func load(core: URL?, content: URL, paused: Bool = false) async throws -> String {
        var arguments: [String: JSONValue] = ["content": .string(content.path(percentEncoded: false))]
        if let core { arguments["core"] = .string(core.path(percentEncoded: false)) }
        if paused { arguments["paused"] = "on" }
        let reply = try await call(.loadContent, arguments).text
        return reply.hasPrefix("LOAD_CONTENT ") ? String(reply.dropFirst("LOAD_CONTENT ".count)) : reply
    }

    public func status() async throws -> GameStatus {
        if !launch.mcp, launch.config.networkCommands {
            guard isRunning else { throw RetroArchSessionError.notRunning }
            let port = launch.config.networkCommandPort
            let reply = await Task.detached {
                NetworkCommands.send("GET_STATUS", port: port, wait: .seconds(2))
            }.value ?? ""
            guard let status = GameStatus(reply: reply) else { throw RetroArchSessionError.unexpectedReply(reply) }
            return status
        }
        let reply = try await call(.status).text
        guard let status = GameStatus(reply: reply) else { throw RetroArchSessionError.unexpectedReply(reply) }
        return status
    }

    public func saveState(slot: Int) async throws {
        try await call(.state, ["action": "save", "slot": .number(Double(slot))])
    }

    public func loadState(slot: Int) async throws {
        try await call(.state, ["action": "load", "slot": .number(Double(slot))])
    }

    public func screenshot() async throws -> Data {
        let result = try await call(.screenshot)
        guard let png = result.images.first else { throw RetroArchSessionError.unexpectedReply(result.text) }
        return png
    }

    // nil turns the shader off.
    public func setShader(_ preset: URL?) async throws {
        try await call(.setShader, ["preset": .string(preset?.path(percentEncoded: false) ?? "")])
    }

    // One of RetroArch's on/off options: runahead, cheevos_hardcore, pause…
    public func setOption(_ option: String, on: Bool) async throws {
        try await call(.setOption, ["option": .string(option), "state": .string(on ? "on" : "off")])
    }

    // An option's value as GET_OPTION reports it: "cheevos_hardcore" gives "on"
    public func option(_ option: String) async throws -> String? {
        let reply = try await call(.getOption, ["option": .string(option)]).text
        for line in reply.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2, fields[0] == option { return String(fields[1]) }
        }
        return nil
    }

    public func log(since: Int) async throws -> (lines: [String], next: Int) {
        let result = try await call(.log, ["since": .number(Double(since))])
        var lines: [String] = []
        var next = since
        for line in result.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("NEXT "), let n = Int(line.dropFirst(5)) {
                next = n
            } else if !line.hasPrefix("SKIPPED "), !line.isEmpty {
                lines.append(String(line))
            }
        }
        if let n = result.structured?["next"]?.int { next = n }
        return (lines, next)
    }

    // Presses RetroPad buttons for some frames; RetroArch refuses it in hardcore
    public func press(player: Int, control: String, frames: Int) async throws -> String {
        try await call(.press, ["player": .number(Double(player)), "control": .string(control),
                                "frames": .number(Double(frames))]).text
    }

    // Hotkeys that are not MCP tools (AI_SERVICE among them) go over the UDP commands, on only when the launch asked.
    public func command(_ name: String) throws {
        guard isRunning else { throw RetroArchSessionError.notRunning }
        guard launch.config.networkCommands else { throw RetroArchSessionError.toolUnavailable(name) }
        _ = NetworkCommands.send(name, port: launch.config.networkCommandPort)
    }

    public enum DiskAction: String, Sendable { case eject, next, prev }

    public func disk(_ action: DiskAction) async throws {
        try await call(.disk, ["action": .string(action.rawValue)])
    }

    public func readMemory(address: Int, bytes: Int) async throws -> [UInt8] {
        let reply = try await call(.readMemory, ["address": .string(String(address, radix: 16)), "bytes": .number(Double(bytes))]).text
        // "READ_CORE_MEMORY 0 1c 02 00 00"; the reply's trailing line break must not cost the last byte.
        return reply.split(whereSeparator: \.isWhitespace).dropFirst(2).compactMap { UInt8($0, radix: 16) }
    }

    public func waitUntilExit() async {
        if let child { _ = await child.exited() }
    }

    // stdin close or UDP QUIT takes the menu-Quit path so the auto save state is written; macOS RetroArch writes nothing on SIGTERM, so a slow build gets SIGTERM then SIGKILL.
    public func stop(within limit: Duration = .seconds(3)) async -> StopReport {
        guard let child else { return StopReport(way: .notRunning, duration: .zero) }
        let started = ContinuousClock.now
        var way = StopReport.Way.quit
        if launch.mcp {
            child.closeInput()
        } else if launch.config.networkCommands {
            _ = NetworkCommands.send("QUIT", port: launch.config.networkCommandPort)
        } else {
            child.signal(SIGTERM)
            way = .terminated
        }
        let grace = max(limit - .milliseconds(600), .milliseconds(100))
        if await !child.waitForExit(within: grace) {
            child.signal(SIGTERM)
            way = .terminated
            if await !child.waitForExit(within: .milliseconds(400)) {
                child.signal(SIGKILL)
                way = .killed
                _ = await child.waitForExit(within: .seconds(2))
            }
        }
        await client?.close()
        reader?.cancel()
        self.child = nil
        client = nil
        reader = nil
        return StopReport(way: way, duration: ContinuousClock.now - started)
    }

    @discardableResult
    private func call(_ need: ToolMap.Need, _ arguments: [String: JSONValue] = [:]) async throws -> ToolResult {
        guard launch.mcp else { throw RetroArchSessionError.needsMCP }
        guard let client, isRunning else { throw RetroArchSessionError.notRunning }
        let tool = try tools.tool(for: need)
        let result = try await client.call(tool, arguments)
        if result.isError { throw RetroArchSessionError.toolFailed(tool: tool, reason: result.text) }
        return result
    }
}
