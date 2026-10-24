// Flags are those of gogdl 1.3.1 (gogdl/args.py) and comet 0.3.2 (src/main.rs).

import Foundation
import InstallerKit

struct GOGAdapter: StoreAdapter {

    let context: ClientContext
    var embed = URL(string: "https://embed.gog.com")!
    var remoteConfig = URL(string: "https://remote-config.gog.com")!
    var productsAPI = URL(string: "https://api.gog.com")!
    var gamesDB = URL(string: "https://gamesdb.gog.com")!
    // A token request must not carry another app's cookies
    var session: URLSession = URLSession(configuration: .ephemeral)

    var store: GameSource { .gog }

    // Where comet looks with --from-heroic, inside the clients' own HOME; gogdl uses the same file
    static let authFile = "Library/Application Support/heroic/gog_store/auth.json"
    static let tokenFiles = [authFile]

    // GOG Galaxy's client, the one gogdl signs in as (gogdl/auth.py)
    static let clientID = "46899977096215655"

    var capabilities: StoreCapabilities {
        StoreCapabilities(client: "gogdl and comet", cloudSaves: true, online: .throughComet)
    }

    private var auth: String { context.home.appending(path: Self.authFile).path(percentEncoded: false) }

    func signInPage() async throws -> SignInPage {
        var url = URLComponents(string: "https://auth.gog.com/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: "https://embed.gog.com/on_login_success?origin=client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "galaxy"),
        ]
        return SignInPage(url: url.url!, codePage: nil)
    }

    func code(at url: URL, pageText: String?) -> String? {
        guard url.host() == "embed.gog.com", url.path() == "/on_login_success" else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        return code?.isEmpty == false ? code : nil
    }

    func finishSignIn(code: String) async throws -> String {
        let output = try await gogdl(["auth", "--code", code], fresh: true)
        guard output.succeeded, let json = StoreJSON.object(output.stdout), json["access_token"] is String else {
            throw StoreError.failed(String(localized: "GOG did not accept the sign-in. Try again."))
        }
        // The account name is GOG's to tell; the tokens are already saved either way
        let user = try? await get(embed.appending(path: "userData.json"), token: json["access_token"] as? String)
        return (user?["username"] as? String) ?? ""
    }

    func signOut() async throws {}

    // GOG's refresh token has no end date in auth.json; a refused refresh says it expired
    func isExpired(_ secret: StoreSecret, now: Date) -> Bool { false }

    // gogdl auth prints fresh credentials, refreshing them first if needed, or null
    func credentials() async throws -> [String: Any] {
        let output = try await gogdl(["auth"])
        guard let json = StoreJSON.object(output.stdout), json["access_token"] is String else {
            // A clean "no token" is an expired session; a crashed gogdl is not
            throw output.succeeded ? StoreError.sessionExpired
                : StoreError.failed(ClientLog.lastError(output.stderr) ?? String(localized: "gogdl stopped with status \(output.status)."))
        }
        return json
    }

    func library() async throws -> [StoreGame] {
        let token = try await credentials()["access_token"] as? String
        var games: [StoreGame] = []
        var page = 1, pages = 1
        repeat {
            var url = URLComponents(url: embed.appending(path: "account/getFilteredProducts"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "mediaType", value: "1"), URLQueryItem(name: "page", value: String(page))]
            let json = try await get(url.url!, token: token)
            pages = json["totalPages"] as? Int ?? 1
            games += (json["products"] as? [[String: Any]] ?? []).compactMap(Self.game)
            page += 1
        } while page <= pages && page <= 100
        return games
    }

    // Games only, with a Windows build
    static func game(_ json: [String: Any]) -> StoreGame? {
        guard let id = (json["id"] as? Int).map(String.init) ?? json["id"] as? String,
              let title = json["title"] as? String,
              (json["isGame"] as? Bool) ?? true,
              (json["worksOn"] as? [String: Any])?["Windows"] as? Bool ?? false else { return nil }
        return StoreGame(id: id, title: title)
    }

    func details(_ game: StoreGame) async -> StoreGame {
        var result = game
        var url = URLComponents(url: productsAPI.appending(path: "products/\(game.id)"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "expand", value: "screenshots")]
        if let json = try? await get(url.url!, token: nil) {
            result = Self.media(json, game: result)
            result.detailsFetchedAt = Date()
        }
        if let output = try? await gogdl(["info", game.id, "--platform", "windows", "--skip-dlcs"]),
           output.succeeded, let json = StoreJSON.object(output.stdout), let size = Self.sizes(json) {
            result.downloadBytes = size.download
            result.diskBytes = size.disk
            result.detailsFetchedAt = Date()
        }
        return result
    }

    static func media(_ json: [String: Any], game: StoreGame) -> StoreGame {
        var result = game
        func url(_ value: Any?) -> URL? {
            guard let text = value as? String,
                  let url = URL(string: text.hasPrefix("//") ? "https:" + text : text),
                  url.scheme == "https" else { return nil }
            return url
        }
        result.header = url((json["images"] as? [String: Any])?["background"]) ?? game.header
        if let shots = json["screenshots"] as? [[String: Any]] {
            result.screenshots = shots.compactMap { shot in
                let images = shot["formatted_images"] as? [[String: Any]] ?? []
                let image = images.first { $0["formatter_name"] as? String == "ggvgl_2x" }
                    ?? images.first { $0["formatter_name"] as? String == "ggvgl" }
                    ?? images.first
                return url(image?["image_url"])
            }
        }
        return result
    }

    static func sizes(_ json: [String: Any]) -> (download: Int64, disk: Int64)? {
        guard let groups = json["size"] as? [String: [String: Any]] else { return nil }
        let language = groups["en-US"] ?? groups["en"] ?? groups.keys.sorted().filter { $0 != "*" }.first.flatMap { groups[$0] }
        let selected = [groups["*"], language].compactMap { $0 }
        let download = selected.reduce(Int64(0)) { $0 + max(0, ($1["download_size"] as? NSNumber)?.int64Value ?? 0) }
        let disk = selected.reduce(Int64(0)) { $0 + max(0, ($1["disk_size"] as? NSNumber)?.int64Value ?? 0) }
        guard download > 0, disk > 0 else { return nil }
        return (download, disk)
    }

    func artURL(_ game: StoreGame) async -> URL? {
        guard let json = try? await get(gamesDB.appending(path: "platforms/gog/external_releases/\(game.id)"), token: nil),
              let format = ((json["game"] as? [String: Any])?["vertical_cover"] as? [String: Any])?["url_format"] as? String
        else { return nil }
        return URL(string: format.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg"))
    }

    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try await checked(["download", game.id, "--platform", "windows", "--path", base.clientPath,
                               "--skip-dlcs"], progress: progress)
        guard let folder = Self.folder(of: game.id, in: base) else {
            throw StoreError.failed(String(localized: "gogdl did not leave the game where Cartouche asked."))
        }
        return StoreInstall(path: folder, version: Self.build(of: game.id, in: folder))
    }

    // For update and repair, --path is the game folder itself; only download appends the game folder under it (gogdl/args.py).
    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        _ = try await checked(["update", id, "--platform", "windows", "--path", install.path.clientPath,
                               "--skip-dlcs"], progress: progress)
        return StoreInstall(path: install.path, version: Self.build(of: id, in: install.path))
    }

    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await checked(["repair", id, "--platform", "windows", "--path", install.path.clientPath,
                               "--skip-dlcs"], progress: progress)
    }

    // gogdl keeps no list of installs: removing the folder is the uninstall
    func uninstall(_ id: String, install: StoreInstall) async throws {
        try? FileManager.default.removeItem(at: install.path)
    }

    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall) {
        guard let found = GOGInfo.primary(in: folder), let game = library.first(where: { $0.id == found.info.id }) else {
            throw StoreError.unknownGame(folder.lastPathComponent)
        }
        return (game, StoreInstall(path: folder, version: Self.build(of: game.id, in: folder)))
    }

    // MARK: Game files

    // goggame-<id>.info, as GOG Galaxy reads it (InstallerKit's GOGInfo).
    static func info(in folder: URL) -> GOGInfo? { GOGInfo.primary(in: folder)?.info }

    static func folder(of id: String, in base: URL) -> URL? {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        return entries.first { FileManager.default.fileExists(atPath: $0.appending(path: "goggame-\(id).info").path(percentEncoded: false)) }
            .map { base.appending(path: $0.lastPathComponent, directoryHint: .isDirectory) }
    }

    static func build(of id: String, in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appending(path: "goggame-\(id).id")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["buildId"] as? String
    }

    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch {
        guard let info = Self.info(in: install.path), let path = info.primaryExe else {
            throw StoreError.failed(String(localized: "The game’s goggame-\(id).info file is missing. Verify its files."))
        }
        return StoreLaunch(executable: PrefixPaths.join(install.path, path), arguments: info.arguments,
                           workingDirectory: PrefixPaths.join(install.path, info.workingDir ?? (path as NSString).deletingLastPathComponent))
    }

    // comet answers the game's GOG Galaxy calls with the account's tokens from auth.json while the game runs, and quits once it disconnects.
    func companion(_ id: String) async throws -> ClientCommand? {
        let executable = try await context.files.ensure(.comet)
        let name = (try? await context.secrets.secret(.gog))?.account ?? ""
        return ClientCommand(executable: executable, arguments: ["--from-heroic", "--username", name.isEmpty ? "player" : name, "--quit"],
                             environment: context.environment)
    }

    // MARK: Cloud saves

    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation] {
        guard let client = Self.info(in: install.path)?.clientID else { return [] }
        var url = URLComponents(url: remoteConfig.appending(path: "components/galaxy_client/clients/\(client)"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "component_version", value: "2.0.45")]
        let json = try await get(url.url!, token: nil)
        guard let storage = ((json["content"] as? [String: Any])?["Windows"] as? [String: Any])?["cloudStorage"] as? [String: Any],
              storage["enabled"] as? Bool == true else { return [] }
        var locations = (storage["locations"] as? [[String: Any]] ?? []).compactMap { entry -> (String, String)? in
            guard let name = entry["name"] as? String, let location = entry["location"] as? String else { return nil }
            return (name, location)
        }
        if locations.isEmpty {
            locations = [("__default", "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/\(client)/Storage/Shared/Files")]
        }
        return locations.compactMap { name, location in
            Self.resolve(location, install: install.path, prefix: prefix).map { SaveLocation(name: name, path: $0) }
        }
    }

    // GOG's <?NAME?> variables (Heroic's save_sync.ts), inside the game's prefix
    static func resolve(_ location: String, install: URL, prefix: URL) -> URL? {
        let roots: [String: URL] = [
            "INSTALL": install, "DOCUMENTS": PrefixPaths.documents(prefix), "SAVED_GAMES": PrefixPaths.savedGames(prefix),
            "APPLICATION_DATA_LOCAL": PrefixPaths.localAppData(prefix),
            "APPLICATION_DATA_LOCAL_LOW": PrefixPaths.user(prefix).appending(path: "AppData/LocalLow"),
            "APPLICATION_DATA_ROAMING": PrefixPaths.roamingAppData(prefix),
        ]
        guard let match = location.firstMatch(of: /^<\?(\w+)\?>/), let root = roots[String(match.1)] else { return nil }
        let rest = String(location[match.range.upperBound...])
        guard !rest.contains("<?"), !rest.contains("%") else { return nil }
        return PrefixPaths.join(root, rest)
    }

    // gogdl compares the files with the time of the last sync and prints the new time
    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String] {
        var stamps = stamps
        for location in locations {
            try FileManager.default.createDirectory(at: location.path, withIntermediateDirectories: true)
            let output = try await checked(["save-sync", location.path.path(percentEncoded: false), id, "--os", "windows",
                                            "--ts", stamps[location.name] ?? "0", "--name", location.name,
                                            direction == .download ? "--skip-upload" : "--skip-download"])
            if let last = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init), Double(last) != nil {
                stamps[location.name] = last
            }
        }
        return stamps
    }

    // MARK: Running gogdl and GOG's APIs

    private func gogdl(_ arguments: [String], fresh: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        // gogdl writes auth-config-path directly; it does not create its parent.
        // A fresh Cartouche HOME has no Heroic directory yet.
        try FileManager.default.createDirectory(at: URL(filePath: auth).deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try await context.run(.gogdl, store: .gog, ["--auth-config-path", auth] + arguments, fresh: fresh) { line in
            if let fraction = ClientProgress.fraction(line) { progress?(fraction) }
        }
    }

    private func checked(_ arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        let output = try await gogdl(arguments, progress: progress)
        if output.stderr.contains("Failed to refresh credentials") || output.stdout.contains("\"error\": true") {
            throw StoreError.sessionExpired
        }
        guard output.succeeded else {
            throw StoreError.failed(ClientLog.lastError(output.stderr) ?? String(localized: "gogdl stopped with status \(output.status)."))
        }
        return output
    }

    private func get(_ url: URL, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw StoreError.sessionExpired }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.failed(String(localized: "GOG answered \(status)."))
        }
        return json
    }
}
