import CartoucheMCP
import Foundation
import InstallerKit
import Network
import RetroArchKit
import Testing

@testable import NotProtonApp

// A backend made of fixtures: enough for tools to answer without Steam,
// RetroArch or an app bundle. Everything the protocol requires returns
// something small; actions are recorded so tests can see them.
@MainActor
final class AgentFixture: AgentBackend {

    var roots: AgentRoots
    var gameList: [Game] = []
    var setups: [String: GameSetupChoice] = [:]
    var favorites: Set<String> = []
    var hidden: Set<String> = []
    var runnerList: [Runner] = []
    var sessionsByGame: [String: [StoredSession]] = [:]
    var consoleGameList: [ConsoleGame] = []
    var playingNow: Playing?
    var logFiles: [String: URL] = [:]
    var calls: [String] = []
    var defaults = GameSetupChoice()

    init(home: URL) {
        roots = AgentRoots(
            support: home.appending(path: "support"), logs: home.appending(path: "logs"),
            installs: home.appending(path: "installs"), retroarch: home.appending(path: "retroarch"),
            caches: home.appending(path: "caches"))
    }

    // MARK: Library
    func games() -> [Game] { gameList }
    func game(_ id: String) -> Game? { gameList.first { $0.id == id } }
    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func isHidden(_ id: String) -> Bool { hidden.contains(id) }
    func setFavorite(_ id: String, on: Bool) {
        calls.append("fav:\(id):\(on)")
        if on { favorites.insert(id) } else { favorites.remove(id) }
    }
    func hide(_ id: String, on: Bool) {
        calls.append("hide:\(id):\(on)")
        if on { hidden.insert(id) } else { hidden.remove(id) }
    }
    func installFolder(of game: Game) -> URL? { roots.installs.appending(path: game.id) }

    // MARK: Setup
    func setupChoice(for id: String) -> GameSetupChoice { setups[id] ?? defaults }
    func setSetup(_ choice: GameSetupChoice, for id: String) {
        calls.append("setup:\(id)")
        setups[id] = choice
    }
    func resolution(for game: Game) -> GameSetupResolver.Resolution {
        GameSetupResolver.resolve(setupChoice(for: game.id), runners: runnerList,
                                  availability: BackendAvailability())
    }
    func graphicsChoices(for game: Game) -> [GraphicsBackend] { [.dxvk, .d3dmetal, .dxmt, .wined3d] }
    func translationChoices(for game: Game) -> [GameSetupChoice.Translation] { [.fex, .rosetta] }
    func hasMacBuild(_ game: Game) -> Bool { false }

    // MARK: Runners
    func runners() -> [Runner] { runnerList }
    func refreshRunners() async -> [Runner] { runnerList }
    func installRunner(_ id: String) async throws { calls.append("installRunner:\(id)") }
    func repairRunner(_ id: String) async throws { calls.append("repairRunner:\(id)") }
    func defaultRunner() -> String? { "wine-staging-11" }
    func setDefaultRunner(_ id: String) { calls.append("defaultRunner:\(id)") }
    func backendAvailability() -> BackendAvailability { BackendAvailability() }

    // MARK: Launch and quit
    func launch(_ game: Game) async throws { calls.append("launch:\(game.id)") }
    func launchStore(_ url: String) async throws { calls.append("store:\(url)") }
    func quit(_ game: Game, force: Bool) async throws { calls.append("quit:\(game.id)") }
    func isRunning(_ game: Game) async -> Bool { false }
    func reportResult(_ game: Game, verdict: String, note: String?) throws {
        calls.append("report:\(verdict)")
    }

    // MARK: Installs
    func analyze(_ path: URL) async throws -> InstallerAnalysis {
        throw AgentToolError("fixture has no installer analysis")
    }
    func startInstall(_ request: InstallRequest, inputs: InstallInputs) -> UUID { UUID() }
    func installJobs() -> [InstallJob] { [] }
    func installJob(_ id: UUID) -> InstallJob? { nil }
    func retryInstall(_ job: InstallJob, fix: RetryFix?) throws { calls.append("retry") }
    func applyThreads(_ job: InstallJob, _ threads: Int) throws {}
    func stopInstall(_ job: InstallJob) throws {}
    func finishInstall(_ job: InstallJob, exe: URL) throws {}
    func cleanupInstaller(_ request: InstallRequest) throws -> Int64 { 0 }
    func copyInstallerToInternal(_ source: URL) throws -> URL { source }

    // MARK: Prefix tools
    func runWinetricks(_ game: Game, verbs: [String]) async throws -> URL {
        calls.append("winetricks:\(verbs.joined(separator: ","))")
        return roots.logs.appending(path: "winetricks.log")
    }
    func registryGet(_ game: Game, key: String, value: String) async throws -> String { "the value" }
    func registrySet(_ game: Game, key: String, value: String, data: String, type: String) async throws {
        calls.append("regset")
    }
    func runInPrefix(_ game: Game, exe: URL, args: [String]) async throws {
        calls.append("runexe:\(exe.lastPathComponent)")
    }

    // MARK: Consoles
    func consoles() -> [Console] { ConsoleCatalog.all }
    func addedConsoles() -> [Console] { [] }
    func consoleGames() -> [ConsoleGame] { consoleGameList }
    func consoleGame(_ id: String) -> ConsoleGame? { consoleGameList.first { $0.id == id } }
    func addConsole(_ id: String) async throws { calls.append("addConsole:\(id)") }
    func removeConsole(_ id: String) async throws { calls.append("removeConsole:\(id)") }
    func biosStatus(_ consoleID: String) -> BIOSStatus? { nil }
    func states(_ game: ConsoleGame) -> [SaveState] { [] }
    func launchConsole(_ game: ConsoleGame, slot: Int?, resume: Bool) async throws {
        calls.append("launchConsole:\(game.id)")
    }
    func consolePlaying() -> Playing? { playingNow }
    func setConsoleSetup(_ id: String,
                         _ change: @escaping @Sendable (inout ConsoleGameSetup) -> Void) async {
        calls.append("consoleSetup:\(id)")
        guard let index = consoleGameList.firstIndex(where: { $0.id == id }) else { return }
        change(&consoleGameList[index].setup)
    }
    func consoleSaveState(_ slot: Int) async throws { calls.append("saveState") }
    func consoleLoadState(_ slot: Int) async throws { calls.append("loadState") }
    func consoleScreenshot() async throws -> Data { Data([0x89, 0x50]) }
    func consoleSwapDisc(_ disc: Int) async throws { calls.append("disc:\(disc)") }
    func consoleQuit() async throws { calls.append("consoleQuit") }
    func identifyFile(_ url: URL) async throws -> Identification? { nil }
    func addConsoleGames(_ games: [ConsoleGame]) async throws { consoleGameList += games }
    func rescanFolders() async { calls.append("rescan") }

    // MARK: Controls
    var controllerList: [ControllerInfo] = []
    var controlsByGame: [String: GameControls] = [:]
    var accessibility = false
    func controllers() -> [ControllerInfo] { controllerList }
    func gameControls(_ id: String) -> GameControls { controlsByGame[id] ?? GameControls() }
    func setGameControls(_ controls: GameControls, for id: String) async throws {
        calls.append("controls:\(id)")
        controlsByGame[id] = controls
    }
    func controlsAccessibility() -> Bool { accessibility }

    // MARK: Diagnostics
    func sessions(_ game: Game) -> [StoredSession] { sessionsByGame[game.id] ?? [] }
    func compatRecord(_ game: Game) -> CompatRecord? { nil }
    func macEntry(_ game: Game) -> MacGamingDBEntry? { nil }
    func gpuStrength() -> [String: Double] { [:] }
    func logFile(_ source: String, for game: Game?) -> URL? { logFiles[source] }
    func installLogFile(_ job: InstallJob) -> URL? { nil }
    func diskFree(at url: URL) -> Int64? { 50_000_000_000 }
}

// MARK: - Helpers

@MainActor
private func fixtureService(
    _ level: AgentLevel = .full, home: URL? = nil
) -> (service: AgentService, backend: AgentFixture) {
    let root = home ?? URL(filePath: NSTemporaryDirectory())
        .appending(path: "cartouche-agent-tests").appending(path: UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let backend = AgentFixture(home: root)
    return (AgentService(backend: backend, level: level, home: root), backend)
}

private func steamGame(appID: Int = 1245620, name: String = "Elden Ring") -> Game {
    Game(id: "steam:\(appID)", source: .steam, name: name, steamAppID: appID, installed: true)
}

private func rpc(_ method: String, id: Int = 1, params: JSONValue? = nil) -> JSONValue {
    var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
    if let params { message["params"] = params }
    return .object(message)
}

// The structuredContent of a service.call reply; nil when the tool errored.
private func payload(_ reply: JSONValue) -> JSONValue? { reply["structuredContent"] }

private func errorText(_ reply: JSONValue) -> String? {
    reply["content"]?.array?.first?["text"]?.string
}

// MARK: - Protocol

@Suite("MCP protocol")
struct MCPProtocolTests {

    @Test("initialize answers the protocol version and server name")
    func initialize() async {
        let server = MCPServer(handler: TestHandler())
        let reply = await server.handle(rpc("initialize", params: [
            "clientInfo": ["name": "claude-test"],
        ]))
        #expect(reply?["result"]?["protocolVersion"] == .string(MCP.protocolVersion))
        #expect(reply?["result"]?["serverInfo"]?["name"] == .string(MCP.serverName))
    }

    @Test("tools/list carries the tool metadata")
    func tools() async {
        let server = MCPServer(handler: TestHandler())
        let reply = await server.handle(rpc("tools/list"))
        let tools = reply?["result"]?["tools"]?.array
        #expect(tools?.first?["name"] == .string("fixture_tool"))
    }

    @Test("tools/call routes to the handler")
    func call() async {
        let server = MCPServer(handler: TestHandler())
        let reply = await server.handle(rpc("tools/call", params: [
            "name": "fixture_tool", "arguments": ["a": "b"],
        ]))
        #expect(reply?["result"]?["structuredContent"]?["called"] == .bool(true))
    }

    @Test("unknown method is a JSON-RPC error, not a crash")
    func unknownMethod() async {
        let server = MCPServer(handler: TestHandler())
        let reply = await server.handle(rpc("nope/nothing"))
        #expect(reply?["error"]?["code"] == .number(-32601))
        #expect(reply?["id"] == .number(1))
    }

    @Test("a notification gets no reply; a batch keeps order")
    func notificationsAndBatch() async {
        let server = MCPServer(handler: TestHandler())
        #expect(await server.handle(rpc("notifications/initialized")) == nil)
        let batch: JSONValue = .array([
            rpc("ping", id: 7),
            rpc("notifications/initialized", id: 8),
            rpc("nope", id: 9),
        ])
        let replies = await server.handle(batch)?.array
        #expect(replies?.count == 2)
        #expect(replies?[0]["id"] == .number(7))
        #expect(replies?[1]["id"] == .number(9))
    }

    @Test("tools/call without a name is invalid params")
    func badCall() async {
        let server = MCPServer(handler: TestHandler())
        let reply = await server.handle(rpc("tools/call", params: ["arguments": [:]]))
        #expect(reply?["error"]?["code"] == .number(-32602))
    }

    @Test("unreachable app still answers with the request id")
    func unreachable() throws {
        let request = rpc("tools/call", id: 42)
        let data = try JSONEncoder().encode(request)
        let reply = MCPUnreachable.reply(to: data, reason: "Cartouche is not running")
        let parsed = try JSONDecoder().decode(JSONValue.self, from: reply)
        #expect(parsed["id"] == .number(42))
        #expect(parsed["error"]?["code"] == .number(-32000))
    }

    private struct TestHandler: MCPHandling {
        var serverVersion: String { "test/1" }
        var clientName: String { "test" }
        func initialize(client: String) async {}
        func tools(client: String) async -> [MCPToolInfo] {
            [MCPToolInfo(name: "fixture_tool", detail: "a tool", schema: .object([:]))]
        }
        func callTool(_ name: String, arguments: JSONValue, client: String) async throws -> JSONValue {
            MCPServer.content(["called": .bool(true)])
        }
    }
}

// MARK: - HTTP transport

@Suite("HTTP MCP transport")
struct MCPHTTPTests {

    @Test("listener parameters are loopback only")
    func loopback() {
        #expect(MCPHTTPServer.parameters().requiredInterfaceType == .loopback)
    }

    @Test("a request without the token is 401, with it reaches the handler")
    func token() async throws {
        let server = MCPHTTPServer(token: "secret-token") { _ in Data("{}".utf8) }
        try server.start(port: 0)
        defer { server.stop() }
        var port: UInt16 = 0
        for _ in 0..<40 where port == 0 {
            try await Task.sleep(for: .milliseconds(50))
            port = server.port
        }
        #expect(port != 0)

        let denied = try await post(port: port, token: "wrong", body: "{}")
        #expect(denied.contains("401"))
        let missing = try await post(port: port, token: nil, body: "{}")
        #expect(missing.contains("401"))
        let ok = try await post(port: port, token: "secret-token", body: "{}")
        #expect(ok.contains("200"))
        #expect(ok.contains("{}"))
    }

    private func post(port: UInt16, token: String?, body: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1",
                                      port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var request = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        let raw = request + "\r\n" + body
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                            data, _, _, error in
                            if let data {
                                continuation.resume(returning: String(decoding: data, as: UTF8.self))
                            } else {
                                continuation.resume(throwing: error ?? CocoaError(.coderReadCorrupt))
                            }
                            connection.cancel()
                        }
                    })
                }
                if case .failed(let error) = state {
                    continuation.resume(throwing: error)
                }
            }
            connection.start(queue: .global())
        }
    }
}

// MARK: - Levels, approvals, log

@Suite("Agent service")
struct AgentServiceTests {

    @Test("read-only level refuses action tools and runs read tools")
    @MainActor
    func levels() async {
        let (service, backend) = fixtureService(.readOnly)
        backend.gameList = [steamGame()]
        let refused = await service.call("set_favorite", ["game": .string("steam:1245620"),
                                                         "on": .bool(true)], client: "test")
        #expect(refused["isError"] == .bool(true))
        #expect(errorText(refused)?.contains("refused") == true)
        #expect(service.actions.contains {
            $0.outcome == .refused("needs standard access; the level is readOnly") })
        let ok = await service.call("list_games", [:], client: "test")
        #expect(ok["isError"] == .bool(false))
        #expect(payload(ok)?["count"] == .number(1))
    }

    @Test("standard level refuses full tools")
    @MainActor
    func fullOnly() async {
        let (service, backend) = fixtureService(.standard)
        backend.gameList = [steamGame()]
        let refused = await service.call("run_winetricks",
            ["game": .string("steam:1245620"), "verbs": .array([.string("vcrun2022")])], client: "test")
        #expect(refused["isError"] == .bool(true))
    }

    @Test("a risky tool waits for the approval; allow runs it")
    @MainActor
    func approvalAllow() async throws {
        let (service, backend) = fixtureService(.full)
        backend.gameList = [steamGame()]
        service.approvalTimeout = .seconds(30)
        let task = Task {
            await service.call("run_winetricks",
                ["game": .string("steam:1245620"), "verbs": .array([.string("vcrun2022")])],
                client: "test")
        }
        for _ in 0..<40 where service.pending.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(service.pending.count == 1)
        #expect(service.pending.first?.tool == "run_winetricks")
        service.answer(service.pending[0].id, allow: true)
        let reply = await task.value
        #expect(reply["isError"] == .bool(false))
        #expect(backend.calls.contains("winetricks:vcrun2022"))
        #expect(service.pending.isEmpty)
    }

    @Test("deny records a denied action and answers an error")
    @MainActor
    func approvalDeny() async throws {
        let (service, backend) = fixtureService(.full)
        backend.gameList = [steamGame()]
        let task = Task {
            await service.call("run_winetricks",
                ["game": .string("steam:1245620"), "verbs": .array([.string("x")])], client: "test")
        }
        for _ in 0..<40 where service.pending.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        service.answer(service.pending[0].id, allow: false)
        let reply = await task.value
        #expect(reply["isError"] == .bool(true))
        #expect(service.actions.contains { $0.outcome == .denied })
        #expect(!backend.calls.contains("winetricks:x"))
    }

    @Test("approval timeout denies on its own")
    @MainActor
    func approvalTimeout() async {
        let (service, backend) = fixtureService(.full)
        backend.gameList = [steamGame()]
        service.approvalTimeout = .milliseconds(80)
        let reply = await service.call("run_winetricks",
            ["game": .string("steam:1245620"), "verbs": .array([.string("x")])], client: "test")
        #expect(reply["isError"] == .bool(true))
        #expect(service.actions.contains { $0.outcome == .denied })
    }

    @Test("undo restores the setup the action changed")
    @MainActor
    func undo() async throws {
        let (service, backend) = fixtureService(.full)
        let game = steamGame()
        backend.gameList = [game]
        var before = GameSetupChoice()
        before.runnerID = "runner-before"
        backend.setups[game.id] = before
        let reply = await service.call("set_game_config",
            ["game": .string(game.id), "config": ["runner": .string("runner-after")]], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(backend.setups[game.id]?.runnerID == "runner-after")
        let action = try #require(service.actions.last { $0.canUndo })
        try await service.undo(action.id)
        #expect(backend.setups[game.id]?.runnerID == "runner-before")
        #expect(service.actions.contains { $0.undone })
    }

    @Test("sendsInput tools are refused while a Hardcore console game runs")
    @MainActor
    func hardcore() async {
        let (service, backend) = fixtureService(.standard)
        var console = ConsoleGame(console: "snes", name: "Test", databaseName: nil,
                                  file: URL(filePath: "/tmp/test.sfc"), identifiedBy: .fileName)
        console.setup.hardcore = true
        backend.consoleGameList = [console]
        backend.playingNow = Playing(gameID: console.id, phase: .playing)
        let reply = await service.call("save_state", ["slot": .number(1)], client: "test")
        #expect(reply["isError"] == .bool(true))
        #expect(errorText(reply)?.contains("Hardcore") == true)
        #expect(!backend.calls.contains("saveState"))
    }
}

// MARK: - Scan

@Suite("Agent scan")
struct AgentScanTests {

    @Test("a planted token and a home path are scrubbed out of every answer")
    @MainActor
    func scrub() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "cartouche-scan-tests").appending(path: UUID().uuidString)
        let (service, backend) = fixtureService(.full, home: root)
        let token = "sk-live-0123456789abcdef0123456789abcdef"
        let log = root.appending(path: "logs/wine.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "error at \(root.path(percentEncoded: false))/drive_c/x and token=\(token)"
            .write(to: log, atomically: true, encoding: .utf8)
        backend.logFiles["wine"] = log
        let game = steamGame()
        backend.gameList = [game]
        let reply = await service.call("get_logs",
            ["game": .string(game.id), "source": .string("wine")], client: "test")
        #expect(reply["isError"] == .bool(false))
        let text = errorText(reply) ?? ""
        #expect(!text.contains(token))
        #expect(!text.contains(root.path(percentEncoded: false)))
    }

    @Test("outside-root paths keep only their file name")
    func outsidePaths() {
        let home = URL(filePath: "/Users/alice")
        let root = URL(filePath: "/Users/alice/Library/Cartouche")
        let inside = root.appending(path: "x.log").path(percentEncoded: false)
        #expect(AgentScan.scrub(.string(inside), under: [root],
                                home: home) == .string("~/Library/Cartouche/x.log"))
        let outside = URL(filePath: "/private/etc/secret.conf").path(percentEncoded: false)
        #expect(AgentScan.scrub(.string(outside), under: [root],
                                home: home) == .string("…/secret.conf"))
    }
}

// MARK: - Diagnose and FPS

@Suite("Agent diagnostics")
struct AgentDiagnoseTests {

    @Test("a missing-DLL log names the DLL and a winetricks fix")
    @MainActor
    func missingDLL() {
        let (_, backend) = fixtureService(.full)
        let diagnosis = AgentDiagnose.diagnose(
            game: steamGame(),
            log: "wine: Call from 0x7b to unimplemented\n"
                + "err:module:import_dll Loading library vcruntime140.dll failed\n",
            backend: backend)
        #expect(diagnosis.problem.contains("vcruntime140.dll"))
        #expect(diagnosis.fixes.contains { $0.tool == "run_winetricks" })
    }

    @Test("a decompressor failure proposes the retry fixes")
    @MainActor
    func isDone() {
        let (_, backend) = fixtureService(.full)
        let diagnosis = AgentDiagnose.diagnose(
            game: steamGame(), log: "unarc.dll returned an error code: -11\n", backend: backend)
        #expect(diagnosis.fixes.count >= 2)
        #expect(diagnosis.fixes.allSatisfy { $0.tool == "retry_install" })
    }

    @Test("FPS history answers every measured session")
    @MainActor
    func fpsHistory() async {
        let (service, backend) = fixtureService(.readOnly)
        let game = steamGame()
        backend.gameList = [game]
        backend.sessionsByGame[game.id] = [
            session(runner: "a", backend: .dxvk, fps: 40),
            session(runner: "b", backend: .d3dmetal, fps: 55),
            session(runner: "a", backend: .dxvk, fps: 60),
        ]
        let reply = await service.call("get_fps_history",
            ["game": .string(game.id)], client: "test")
        #expect(reply["isError"] == .bool(false))
        #expect(payload(reply)?["count"] == .number(3))
        let sessions = payload(reply)?["sessions"]?.array
        #expect(sessions?.first?["runner"] == .string("a"))
    }

    private func session(runner: String, backend: GraphicsBackend, fps: Double) -> StoredSession {
        var measured = PlayStats.Measured()
        measured.seconds = 60
        measured.frames = Int(fps * 60)
        var session = StoredSession(
            appID: 1245620,
            setup: PlaySetup(runnerID: runner, translation: .rosetta, backend: backend),
            runnerName: runner,
            started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 60),
            measurement: .on)
        session.measured = measured
        return session
    }
}

// MARK: - Contract: every read tool answers on the fixture

@Suite("Read tool contract")
struct AgentContractTests {

    // Tools the fixture serves fully: no real disk data beyond the log file.
    private let served: [String: JSONValue] = [
        "list_games": [:],
        "get_game": ["game": "steam:1245620"],
        "get_game_config": ["game": "steam:1245620"],
        "get_fps_history": ["game": "steam:1245620"],
        "compare_setups": ["game": "steam:1245620"],
        "get_logs": ["game": "steam:1245620", "source": "app"],
        "diagnose": ["game": "steam:1245620"],
        "suggest_fps_boost": ["game": "steam:1245620"],
        "get_mac_info": [:],
        "get_storage": [:],
        "get_activity": [:],
        "get_running": [:],
        "list_runners": [:],
        "get_prefix_files": ["game": "steam:1245620"],
        "list_consoles": [:],
        "list_states": ["game": "console:snes:file:test.sfc"],
    ]

    @Test("every read tool the fixture can serve returns a result, not an error")
    @MainActor
    func readTools() async throws {
        let (service, backend) = fixtureService(.readOnly)
        let log = backend.roots.logs.appending(path: "app.log")
        try FileManager.default.createDirectory(at: backend.roots.logs,
                                                withIntermediateDirectories: true)
        try "line\n".write(to: log, atomically: true, encoding: .utf8)
        backend.logFiles["app"] = log
        backend.gameList = [steamGame()]
        backend.consoleGameList = [ConsoleGame(
            console: "snes", name: "Test", databaseName: nil,
            file: URL(filePath: "/tmp/test.sfc"), identifiedBy: .fileName)]
        var failures: [String] = []
        for (name, args) in served {
            let reply = await service.call(name, args, client: "test")
            if reply["isError"] == .bool(true) { failures.append(name) }
        }
        #expect(failures.isEmpty)
    }

    @Test("tools whose data the fixture lacks answer a tool error, not a crash")
    @MainActor
    func missingData() async {
        let (service, _) = fixtureService(.readOnly)
        for name in ["get_compatibility", "get_bios_status", "identify_file"] {
            let reply = await service.call(name,
                .object(["game": .string("steam:1245620"),
                         "path": .string("/tmp/x")]), client: "test")
            #expect(reply["isError"] == .bool(true))
            #expect(reply["content"]?.array?.first?["type"] == .string("text"))
        }
    }
}
