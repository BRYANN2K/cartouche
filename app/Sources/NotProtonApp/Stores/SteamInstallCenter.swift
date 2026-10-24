import AppKit
import Foundation
import Observation

@MainActor @Observable
final class SteamInstallCenter {
    static let shared = SteamInstallCenter()

    struct License: Identifiable {
        let id: String
        let url: URL
    }
    struct Status {
        let game: Game
        let state: String
        let message: String?
        let licenses: [License]
    }

    private(set) var status: Status?
    @ObservationIgnored var support = SupportPaths.support
    @ObservationIgnored var integrationVersion: () -> String? = {
        (try? DeploymentContent.readBuild(at: DeploymentContent.record(beside: SupportPaths.deployedVersion)))?.integrationVersion
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: [String: Any] = [:]
    @ObservationIgnored private var licensePayload: [[String: Any]] = []

    func clear(appID: Int) {
        guard status?.game.steamAppID == appID else { return }
        task?.cancel()
        task = nil
        status = nil
        request = [:]
        licensePayload = []
    }

    func reconcile(_ snapshot: SteamActivitySnapshot) {
        guard let appID = status?.game.steamAppID else { return }
        if snapshot.installed.contains(appID) || snapshot.downloads.contains(where: { $0.appID == appID }) {
            clear(appID: appID)
        }
    }

    func install(_ game: Game, model: LibraryModel, destination: URL) {
        guard let appID = game.steamAppID, let account = model.steam.account else {
            model.problem = String(localized: "Sign in to Steam first.")
            return
        }
        guard let version = integrationVersion(),
              CartoucheVersion.compare(version, "0.1.0-4") != .orderedAscending else {
            status = Status(game: game, state: "failed", message: String(localized: "Update the Steam integration in Settings > Steam to install games in the background."), licenses: [])
            return
        }
        if let status, ["preparing", "license"].contains(status.state) {
            model.problem = String(localized: "Finish the current installation first.")
            return
        }
        let setup = model.resolution(for: game).setup
        let tool = GameSetupApplier.tool(for: setup, in: model.backendTools)?.name ?? ""
        request = ["appid": appID, "steamid": account.steamID, "tool": tool,
                   "destination": destination.path(percentEncoded: false)]
        send("install", game: game)
        if model.steam.presence == .closed {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            config.arguments = ["-silent"]
            NSWorkspace.shared.openApplication(at: SupportPaths.Steam.app, configuration: config) { _, _ in }
        }
    }

    func accept() {
        guard let status, status.state == "license", !licensePayload.isEmpty else { return }
        request["licenses"] = licensePayload
        send("accept", game: status.game)
    }

    func cancel() {
        guard let status else { return }
        send("cancel", game: status.game)
    }

    private func send(_ operation: String, game: Game) {
        task?.cancel()
        let id = UUID().uuidString
        request["id"] = id
        request["operation"] = operation
        request["created"] = Int(Date().timeIntervalSince1970)
        do {
            let file = support.appending(path: "steam-install-command.json")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            try atomicReplace(file, with: bytes, step: String(localized: "Install game"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
            status = Status(game: game, state: "preparing", message: nil, licenses: [])
        } catch {
            status = Status(game: game, state: "failed", message: error.localizedDescription, licenses: [])
            return
        }
        task = Task { [weak self] in
            let deadline = Date().addingTimeInterval(75)
            while !Task.isCancelled && Date() < deadline {
                guard let self else { return }
                if let value = self.readStatus(id: id, game: game) {
                    self.status = value
                    if value.state != "preparing" { return }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self else { return }
            self.status = Status(game: game, state: "failed",
                message: String(localized: "Steam did not answer. Check that it is signed in and update the Steam integration in Settings."), licenses: [])
        }
    }

    private func readStatus(id: String, game: Game) -> Status? {
        let file = support.appending(path: "steam-install-status.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16384,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == id, json["appid"] as? Int == game.steamAppID,
              let state = json["state"] as? String else { return nil }
        licensePayload = json["licenses"] as? [[String: Any]] ?? []
        let licenses = licensePayload.compactMap { row -> License? in
            guard let string = row["url"] as? String, let url = URL(string: string), url.scheme == "https" else { return nil }
            return License(id: String(describing: row["id"] ?? string), url: url)
        }
        let message = json["message"] as? String
        return Status(game: game, state: state, message: message == "integration-update-required"
            ? String(localized: "Update the Steam integration in Settings > Steam to install games in the background.") : message, licenses: licenses)
    }
}
