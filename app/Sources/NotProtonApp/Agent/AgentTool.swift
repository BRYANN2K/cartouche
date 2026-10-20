import CartoucheMCP
import Foundation
import InstallerKit
import RetroArchKit

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
    func reportResult(_ game: Game, verdict: String, note: String?) throws

    // MARK: Installs
    func analyze(_ path: URL) async throws -> InstallerAnalysis
    func startInstall(_ request: InstallRequest, inputs: InstallInputs) -> UUID
    func installJobs() -> [InstallJob]
    func installJob(_ id: UUID) -> InstallJob?
    func retryInstall(_ job: InstallJob, fixes: [RetryFix]) throws
    func stopInstall(_ job: InstallJob) throws
    func finishInstall(_ job: InstallJob, exe: URL) throws
    func cleanupInstaller(_ request: InstallRequest) throws -> Int64
    func copyInstallerToInternal(_ source: URL) async throws -> URL

    // MARK: Prefix tools (Full level)
    func prefixFolder(_ game: Game) -> URL?
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
    func biosStatus(_ consoleID: String) async -> BIOSStatus?
    func states(_ game: ConsoleGame) async -> [SaveState]
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

    // MARK: Controls — through the same ControlsCenter the sheet uses
    func controllers() -> [ControllerInfo]
    func gameControls(_ id: String) -> GameControls
    func setGameControls(_ controls: GameControls, for id: String) async throws
    // Accessibility, the permission "Play with a controller" needs. The app asks for it; an agent only reads whether macOS granted it.
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
    var approvalText: (@MainActor (AgentBackend, JSONValue) async -> String)?
    var run: @MainActor (AgentBackend, JSONValue) async throws -> JSONValue
}

protocol AgentToolProvider {
    func tools() -> [AgentTool]
}

// MARK: - Argument helpers

extension JSONValue {
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
