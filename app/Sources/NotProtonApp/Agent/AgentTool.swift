import CartoucheMCP
import Foundation
import InstallerKit
import RetroArchKit

// What the agent-facing side of the app exposes. The app's own models back the
// live implementation; tests swap in fixtures. Keeping this a protocol keeps
// every tool testable without an app bundle, Steam, or RetroArch.
@MainActor
protocol AgentBackend {

    var roots: AgentRoots { get }

    // MARK: Library
    func games() -> [Game]
    func game(_ id: String) -> Game?
    func isFavorite(_ id: String) -> Bool
    func isHidden(_ id: String) -> Bool
    func setFavorite(_ id: String, on: Bool)
    func hide(_ id: String, on: Bool)
    func installFolder(of game: Game) -> URL?

    // MARK: Setup
    func setupChoice(for id: String) -> GameSetupChoice
    func setSetup(_ choice: GameSetupChoice, for id: String)
    func resolution(for game: Game) -> GameSetupResolver.Resolution
    func graphicsChoices(for game: Game) -> [GraphicsBackend]
    func translationChoices(for game: Game) -> [GameSetupChoice.Translation]
    func hasMacBuild(_ game: Game) -> Bool

    // MARK: Runners
    func runners() -> [Runner]
    func refreshRunners() async -> [Runner]
    func installRunner(_ id: String) async throws
    func repairRunner(_ id: String) async throws
    func defaultRunner() -> String?
    func setDefaultRunner(_ id: String)
    func backendAvailability() -> BackendAvailability

    // MARK: Launch and quit (PC and console through the same tools)
    func launch(_ game: Game) async throws
    func launchStore(_ url: String) async throws
    func quit(_ game: Game, force: Bool) async throws
    func isRunning(_ game: Game) async -> Bool
    func reportResult(_ game: Game, verdict: String, note: String?) throws

    // MARK: Installs
    func analyze(_ path: URL) async throws -> InstallerAnalysis
    func startInstall(_ request: InstallRequest, inputs: InstallInputs) -> UUID
    func installJobs() -> [InstallJob]
    func installJob(_ id: UUID) -> InstallJob?
    func retryInstall(_ job: InstallJob, fix: RetryFix?) throws
    // A fix outside RetryFix's own vocabulary: the mockup's single_thread.
    func applyThreads(_ job: InstallJob, _ threads: Int) throws
    func stopInstall(_ job: InstallJob) throws
    func finishInstall(_ job: InstallJob, exe: URL) throws
    func cleanupInstaller(_ request: InstallRequest) throws -> Int64
    func copyInstallerToInternal(_ source: URL) throws -> URL

    // MARK: Prefix tools (Full level)
    func runWinetricks(_ game: Game, verbs: [String]) async throws -> URL
    func registryGet(_ game: Game, key: String, value: String) async throws -> String
    func registrySet(_ game: Game, key: String, value: String, data: String, type: String) async throws
    func runInPrefix(_ game: Game, exe: URL, args: [String]) async throws

    // MARK: Consoles — relayed through Cartouche, never a direct endpoint
    func consoles() -> [Console]
    func addedConsoles() -> [Console]
    func consoleGames() -> [ConsoleGame]
    func consoleGame(_ id: String) -> ConsoleGame?
    func addConsole(_ id: String) async throws
    func removeConsole(_ id: String) async throws
    func biosStatus(_ consoleID: String) -> BIOSStatus?
    func states(_ game: ConsoleGame) -> [SaveState]
    func launchConsole(_ game: ConsoleGame, slot: Int?, resume: Bool) async throws
    func consolePlaying() -> Playing?
    func setConsoleSetup(_ id: String, _ change: @escaping @Sendable (inout ConsoleGameSetup) -> Void) async
    func consoleSaveState(_ slot: Int) async throws
    func consoleLoadState(_ slot: Int) async throws
    func consoleScreenshot() async throws -> Data
    func consoleSwapDisc(_ disc: Int) async throws
    func consoleQuit() async throws
    func identifyFile(_ url: URL) async throws -> Identification?
    func addConsoleGames(_ games: [ConsoleGame]) async throws
    func rescanFolders() async

    // MARK: Controls — through the same ControlsCenter the sheet uses (P15)
    func controllers() -> [ControllerInfo]
    func gameControls(_ id: String) -> GameControls
    func setGameControls(_ controls: GameControls, for id: String) async throws
    // Accessibility, the permission "Play with a controller" needs. The app
    // asks for it; an agent only reads whether macOS granted it.
    func controlsAccessibility() -> Bool

    // MARK: Diagnostics and system
    func sessions(_ game: Game) -> [StoredSession]
    func compatRecord(_ game: Game) -> CompatRecord?
    func macEntry(_ game: Game) -> MacGamingDBEntry?
    func gpuStrength() -> [String: Double]
    // The log a source names: "wine", "launch", "installer", "console", "app".
    func logFile(_ source: String, for game: Game?) -> URL?
    func installLogFile(_ job: InstallJob) -> URL?
    func diskFree(at url: URL) -> Int64?
}

struct AgentToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

// One MCP tool: its wire shape and which checks stand between a call and the
// app's own functions. The registry lives in AgentTools.swift; P15 will add
// controller tools by appending to AgentToolProvider lists.
struct AgentTool {
    var name: String
    var detail: String
    var schema: JSONValue
    var level: AgentLevel = .readOnly
    // Waits for the user in the app before running (installs, deletes, exe runs)
    var approval = false
    // Sends input or changes the running game's state: refused while Hardcore is on
    var sendsInput = false
    var readOnly = true
    var destructive = false
    // The "<Game> (<size>)" the approval line shows for this call
    var approvalText: (@MainActor (AgentBackend, JSONValue) -> String)?
    var run: @MainActor (AgentBackend, JSONValue) async throws -> JSONValue

    // P15 extension point: controller tools register through
    // AgentToolProvider below; AgentService asks every provider for its list.
}

// A bag of tools a later phase adds without touching AgentService: P15's
// controller tools become an AgentControls provider next to this registry.
protocol AgentToolProvider {
    func tools() -> [AgentTool]
}

// MARK: - Argument helpers

extension JSONValue {
    var requiredGame: String? { self["game"]?.string }

    func require(_ key: String) throws -> String {
        guard let value = self[key]?.string, !value.isEmpty else {
            throw MCPError.invalidParams("missing \"\(key)\"")
        }
        return value
    }

    func requireInt(_ key: String) throws -> Int {
        guard let value = self[key]?.int else { throw MCPError.invalidParams("missing \"\(key)\"") }
        return value
    }
}
