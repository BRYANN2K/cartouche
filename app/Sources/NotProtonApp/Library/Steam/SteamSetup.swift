
import Foundation
import Observation

@MainActor
@Observable
final class SteamSetup {

    enum Stage: Equatable {
        case idle
        case downloading
        case installingWithHomebrew
        case signIn
        case failed(String)
    }

    nonisolated static var valveInstaller: URL {
        QAEnvironment.url(URL(string: "https://cdn.fastly.steamstatic.com/client/installer/steam.dmg")!)
    }
    static let homebrewCommand = "brew install --cask steam"
    nonisolated static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private(set) var stage: Stage = .idle

    struct Steps: Sendable {
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
    @ObservationIgnored var onInstalled: @MainActor () -> Void = {}

    init(steps: Steps = Steps(), defaults: UserDefaults = .standard) {
        self.steps = steps
        self.defaults = defaults
    }

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
        // hdiutil, codesign and a multi-hundred-MB ditto are process waits: never on the main actor.
        try await Task.detached {
            let attach = try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
            guard attach.succeeded else { throw Failed(errorDescription: attach.stderr) }
            defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let app = mount.appending(path: "Steam.app")
            try verifyValveApp(app)
            let destination = applications.appending(path: "Steam.app")
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
                throw Failed(errorDescription: String(localized: "Steam is already in \(applications.lastPathComponent)."))
            }
            let copy = try Shell.run("/usr/bin/ditto", [app.path, destination.path])
            guard copy.succeeded else { throw Failed(errorDescription: copy.stderr) }
        }.value
    }

    // Only Valve's signature may land in Applications; HTTPS alone does not prove the DMG is Valve's, as the URL can be re-pointed in QA mode
    nonisolated static func verifyValveApp(_ app: URL) throws {
        let check = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path(percentEncoded: false)])
        guard check.succeeded else {
            throw Failed(errorDescription: check.stderr.isEmpty
                ? String(localized: "The downloaded Steam app is not signed.")
                : check.stderr)
        }
        let signature = try Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path(percentEncoded: false)])
        guard (signature.stdout + signature.stderr).contains("TeamIdentifier=MXGJJ98X76") else {
            throw Failed(errorDescription: String(localized: "The downloaded Steam app is not signed by Valve."))
        }
    }

    @Sendable static func brewInstall(_ brew: String) async throws {
        let result = try await Task.detached { try Shell.run(brew, ["install", "--cask", "steam"]) }.value
        guard result.succeeded else { throw Failed(errorDescription: result.stderr) }
    }
}
