// The three ways to get Steam when it is not on this Mac: Valve's own installer,
// Homebrew when it is installed, or pointing Cartouche at a Steam that is elsewhere.

import Foundation
import Observation

@MainActor
@Observable
final class SteamSetup {

    enum Stage: Equatable {
        case idle
        case downloading
        case installingWithHomebrew
        // Steam is in place, the user signs in once in Steam
        case signIn
        case failed(String)
    }

    nonisolated static let valveInstaller = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/steam.dmg")!
    static let homebrewCommand = "brew install --cask steam"
    nonisolated static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private(set) var stage: Stage = .idle

    struct Steps: Sendable {
        // Downloads Valve's installer and moves Steam.app into the folder
        var downloadAndInstall: @Sendable (_ into: URL) async throws -> Void = SteamSetup.installFromValve
        var runBrew: @Sendable (_ brew: String) async throws -> Void = SteamSetup.brewInstall
        var brewPath: @Sendable () -> String? = {
            SteamSetup.brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        var bundleID: @Sendable (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
        var applications = URL(filePath: "/Applications")
    }

    @ObservationIgnored let steps: Steps
    @ObservationIgnored let defaults: UserDefaults
    // Called once Steam is in place, so the library loads it
    @ObservationIgnored var onInstalled: @MainActor () -> Void = {}

    init(steps: Steps = Steps(), defaults: UserDefaults = .standard) {
        self.steps = steps
        self.defaults = defaults
    }

    // Shown only when Homebrew is on this Mac
    var homebrew: String? { steps.brewPath() }

    var isWorking: Bool { stage == .downloading || stage == .installingWithHomebrew }

    func downloadSteam() async {
        stage = .downloading
        do {
            try await steps.downloadAndInstall(steps.applications)
            stage = .signIn
            onInstalled()
        } catch {
            stage = .failed(String(localized: "Steam could not be installed: \(error.localizedDescription)"))
        }
    }

    func installWithHomebrew() async {
        guard let brew = homebrew else { return }
        stage = .installingWithHomebrew
        do {
            try await steps.runBrew(brew)
            stage = .signIn
            onInstalled()
        } catch {
            stage = .failed(String(localized: "Homebrew could not install Steam: \(error.localizedDescription)"))
        }
    }

    // Accepts only Valve's Steam app, and remembers where it is
    @discardableResult
    func locate(_ app: URL) -> Bool {
        guard steps.bundleID(app) == SteamRepair.valveIdentifier else {
            stage = .failed(String(localized: "\(app.lastPathComponent) is not Steam."))
            return false
        }
        defaults.set(app.path(percentEncoded: false), forKey: SupportPaths.Steam.appPathKey)
        stage = .signIn
        onInstalled()
        return true
    }

    func reset() { stage = .idle }

    // MARK: Live steps

    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    @Sendable static func installFromValve(into applications: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: valveInstaller)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failed(errorDescription: String(localized: "Valve’s server did not send the installer."))
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "cartouche-steam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dmg = work.appending(path: "steam.dmg")
        try FileManager.default.moveItem(at: file, to: dmg)
        let mount = work.appending(path: "mount")
        let attach = try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        guard attach.succeeded else { throw Failed(errorDescription: attach.stderr) }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let copy = try Shell.run("/usr/bin/ditto", [mount.appending(path: "Steam.app").path, applications.appending(path: "Steam.app").path])
        guard copy.succeeded else { throw Failed(errorDescription: copy.stderr) }
    }

    @Sendable static func brewInstall(_ brew: String) async throws {
        let result = try await Task.detached { try Shell.run(brew, ["install", "--cask", "steam"]) }.value
        guard result.succeeded else { throw Failed(errorDescription: result.stderr) }
    }
}
