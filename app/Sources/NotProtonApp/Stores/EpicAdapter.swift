// Epic Games through legendary. The user signs in on Epic's own page, which
// ends on a JSON page holding a one-time authorization code; legendary trades
// it for tokens in user.json, which the vault keeps. Commands and flags are
// those of legendary 0.21.1 (legendary/cli.py).

import Foundation

struct EpicAdapter: StoreAdapter {

    let context: ClientContext
    var store: GameSource { .epic }

    static let tokenFiles = ["user.json"]

    // Epic's launcher client, the one legendary signs in as (legendary/api/egs.py)
    static let clientID = "34a02cf8f4414e29b15921876da36f9a"

    var capabilities: StoreCapabilities {
        StoreCapabilities(client: "legendary", cloudSaves: true, online: .dependsOnGame)
    }

    func signInPage() async throws -> SignInPage {
        let redirect = "https://www.epicgames.com/id/api/redirect?clientId=\(Self.clientID)&responseType=code"
        var url = URLComponents(string: "https://www.epicgames.com/id/login")!
        url.queryItems = [URLQueryItem(name: "redirectUrl", value: redirect)]
        return SignInPage(url: url.url!, codePage: URL(string: "https://www.epicgames.com/id/api/redirect"))
    }

    func code(at url: URL, pageText: String?) -> String? {
        guard url.host() == "www.epicgames.com", url.path() == "/id/api/redirect", let pageText,
              let json = StoreJSON.object(pageText), let code = json["authorizationCode"] as? String, !code.isEmpty
        else { return nil }
        return code
    }

    func finishSignIn(code: String) async throws -> String {
        let output = try await legendary(["auth", "--code", code], fresh: true)
        guard output.succeeded, !output.stderr.contains("Login attempt failed") else {
            throw StoreError.failed(String(localized: "Epic Games did not accept the sign-in. Try again."))
        }
        if let name = Self.signedInName(output.stderr) { return name }
        let status = try await legendary(["status", "--json", "--offline"])
        return (StoreJSON.object(status.stdout)?["account"] as? String) ?? ""
    }

    // 'Successfully logged in as "player42"'
    static func signedInName(_ log: String) -> String? {
        guard let range = log.range(of: "Successfully logged in as \"") else { return nil }
        let rest = log[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    func signOut() async throws {
        _ = try await legendary(["auth", "--delete"])
    }

    func isExpired(_ secret: StoreSecret, now: Date) -> Bool {
        guard let data = secret.files["user.json"],
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["refresh_expires_at"] as? String,
              let date = Self.date(text) else { return false }
        return date <= now
    }

    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func library() async throws -> [StoreGame] {
        let output = try await checked(["list", "--json"])
        guard let list = StoreJSON.array(output.stdout) else {
            throw StoreError.failed(String(localized: "legendary returned a library Cartouche couldn’t read."))
        }
        return list.compactMap { $0 as? [String: Any] }.compactMap(Self.game)
    }

    static func game(_ json: [String: Any]) -> StoreGame? {
        guard let id = json["app_name"] as? String, let title = json["app_title"] as? String else { return nil }
        let metadata = json["metadata"] as? [String: Any] ?? [:]
        let images = metadata["keyImages"] as? [[String: Any]] ?? []
        let tall = images.first { $0["type"] as? String == "DieselGameBoxTall" } ?? images.first { $0["type"] as? String == "DieselGameBox" }
        let attributes = metadata["customAttributes"] as? [String: Any] ?? [:]
        return StoreGame(id: id, title: title, art: (tall?["url"] as? String).flatMap(URL.init(string:)),
                         cloudSaves: attributes["CloudSaveFolder"] != nil)
    }

    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        _ = try await checked(["-y", "install", game.id, "--base-path", base.clientPath,
                               "--platform", "Windows", "--skip-sdl"], progress: progress)
        return try await installed(game.id)
    }

    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        _ = try await checked(["-y", "install", id, "--update-only", "--skip-sdl"], progress: progress)
        return try await installed(id)
    }

    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await checked(["-y", "install", id, "--repair", "--skip-sdl"], progress: progress)
    }

    func uninstall(_ id: String, install: StoreInstall) async throws {
        _ = try await checked(["-y", "uninstall", id, "--skip-uninstaller"])
    }

    func forget(_ id: String) async throws {
        _ = try await checked(["-y", "uninstall", id, "--keep-files", "--skip-uninstaller"])
    }

    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall) {
        guard let appName = Self.appName(in: folder), let game = library.first(where: { $0.id == appName }) else {
            throw StoreError.unknownGame(folder.lastPathComponent)
        }
        _ = try await checked(["-y", "import", appName, folder.clientPath, "--platform", "Windows"])
        return (game, try await installed(appName))
    }

    // The Epic launcher leaves .egstore/<id>.mancpn with the game's AppName
    static func appName(in folder: URL) -> String? {
        let store = folder.appending(path: ".egstore")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.path(percentEncoded: false))) ?? []
        for file in files.sorted() where file.hasSuffix(".mancpn") {
            if let data = try? Data(contentsOf: store.appending(path: file)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["AppName"] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private func installed(_ id: String) async throws -> StoreInstall {
        let output = try await legendary(["list-installed", "--json"])
        let list = StoreJSON.array(output.stdout)?.compactMap { $0 as? [String: Any] } ?? []
        guard let entry = list.first(where: { $0["app_name"] as? String == id }),
              let path = entry["install_path"] as? String else {
            throw StoreError.failed(String(localized: "legendary did not report where the game was installed."))
        }
        return StoreInstall(path: URL(filePath: path, directoryHint: .isDirectory), version: entry["version"] as? String)
    }

    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch {
        var arguments = ["launch", id, "--json", "--no-wine", "--skip-version-check"]
        if offline { arguments.append("--offline") }
        let output = try await checked(arguments)
        guard let json = StoreJSON.object(output.stdout) else {
            throw StoreError.failed(String(localized: "legendary did not say how to start the game."))
        }
        return try Self.launch(json)
    }

    // legendary's LaunchParameters, as --json prints them
    static func launch(_ json: [String: Any]) throws -> StoreLaunch {
        guard let directory = json["game_directory"] as? String, let exe = json["game_executable"] as? String else {
            throw StoreError.failed(String(localized: "legendary did not say how to start the game."))
        }
        let strings = { (key: String) in (json[key] as? [String] ?? []).filter { !$0.isEmpty } }
        let base = URL(filePath: directory, directoryHint: .isDirectory)
        let working = (json["working_directory"] as? String).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? base
        return StoreLaunch(executable: PrefixPaths.join(base, exe),
                           arguments: strings("game_parameters") + strings("egl_parameters") + strings("user_parameters"),
                           workingDirectory: working,
                           environment: json["environment"] as? [String: String] ?? [:])
    }

    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation] {
        let metadata = context.folder.appending(path: "metadata/\(id).json")
        guard let data = try? Data(contentsOf: metadata),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attributes = (json["metadata"] as? [String: Any])?["customAttributes"] as? [String: Any],
              let folder = (attributes["CloudSaveFolder"] as? [String: Any])?["value"] as? String else { return [] }
        let account = try await accountID()
        guard let path = Self.savePath(folder, install: install.path, prefix: prefix, accountID: account) else { return [] }
        return [SaveLocation(name: "__default", path: path)]
    }

    // legendary's own variables (core.get_save_path), resolved inside the game's prefix
    static func savePath(_ pattern: String, install: URL, prefix: URL, accountID: String?) -> URL? {
        let slashed = pattern.replacingOccurrences(of: "\\", with: "/")
        let roots: [(String, URL)] = [
            ("{installdir}", install), ("{appdata}", PrefixPaths.localAppData(prefix)),
            ("{userdir}", PrefixPaths.documents(prefix)), ("{userprofile}", PrefixPaths.user(prefix)),
            ("{usersavedgames}", PrefixPaths.savedGames(prefix)),
        ]
        guard let (variable, root) = roots.first(where: { slashed.lowercased().hasPrefix($0.0) }) else { return nil }
        var rest = String(slashed.dropFirst(variable.count))
        if let accountID { rest = rest.replacingOccurrences(of: "{EpicId}", with: accountID, options: .caseInsensitive) }
        guard !rest.contains("{"), !rest.contains("%") else { return nil }
        return PrefixPaths.join(root, rest)
    }

    private func accountID() async throws -> String? {
        guard let data = try await context.secrets.secret(.epic)?.files["user.json"],
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["account_id"] as? String
    }

    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String] {
        for location in locations {
            try FileManager.default.createDirectory(at: location.path, withIntermediateDirectories: true)
            _ = try await checked(["-y", "sync-saves", id, "--save-path", location.path.path(percentEncoded: false),
                                   direction == .download ? "--skip-upload" : "--skip-download"])
        }
        return stamps
    }

    // MARK: Running legendary

    private func legendary(_ arguments: [String], fresh: Bool = false,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        try await context.run(.legendary, store: .epic, arguments, fresh: fresh) { line in
            if let fraction = ClientProgress.fraction(line) { progress?(fraction) }
        }
    }

    // A refused login is an expired session; any other failure keeps legendary's last error line
    private func checked(_ arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        let output = try await legendary(arguments, progress: progress)
        if Self.loginRefused(output) { throw StoreError.sessionExpired }
        guard output.succeeded else {
            throw StoreError.failed(ClientLog.lastError(output.stderr) ?? String(localized: "legendary stopped with status \(output.status)."))
        }
        return output
    }

    static func loginRefused(_ output: ClientOutput) -> Bool {
        ["Login failed", "No saved credentials", "no longer valid", "InvalidCredentialsError"].contains { output.stderr.contains($0) }
    }

}
