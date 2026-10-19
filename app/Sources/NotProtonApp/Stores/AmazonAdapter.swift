// Amazon Games through nile. nile prepares the sign-in (a device serial and a
// code verifier) and prints Amazon's own page; once the user signs in there,
// Amazon sends the browser to amazon.com with a one-time code, which nile
// registers as a device. Its tokens live in nile/<hash>.enc and
// current_user.json, which the vault keeps. Flags are those of nile 1.2.0
// (nile/arguments.py). nile 1.2.0 has no cloud save command.

import Foundation

struct AmazonAdapter: StoreAdapter {

    let context: ClientContext
    var store: GameSource { .amazon }

    static let tokenFiles = ["nile/current_user.json", "nile/*.enc"]

    // nile 1.2.0's commands, from nile/arguments.py. Cloud saves would need one.
    static let commands: Set<String> = ["auth", "register", "library", "install", "update", "verify", "list-updates",
                                        "launch", "uninstall", "import"]

    var capabilities: StoreCapabilities {
        StoreCapabilities(client: "nile", downloads: true, cloudSaves: Self.commands.contains("sync-saves"),
                          online: .notSupported)
    }

    // The sign-in nile prepared, kept in memory until Amazon hands over the code
    private let pending = Pending()

    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]?
        func set(_ new: [String: String]?) { lock.withLock { value = new } }
        func get() -> [String: String]? { lock.withLock { value } }
    }

    func signInPage() async throws -> SignInPage {
        let output = try await nile(["auth", "--login", "--non-interactive"])
        guard let json = StoreJSON.object(output.stdout),
              let page = (json["url"] as? String).flatMap(URL.init(string:)),
              let client = json["client_id"] as? String, let verifier = json["code_verifier"] as? String,
              let serial = json["serial"] as? String else {
            throw StoreError.failed(ClientLog.lastError(output.stderr) ?? String(localized: "nile could not prepare the Amazon sign-in."))
        }
        pending.set(["client_id": client, "code_verifier": verifier, "serial": serial])
        return SignInPage(url: page, codePage: nil)
    }

    // Amazon returns to https://www.amazon.com/?openid.oa2.authorization_code=...
    func code(at url: URL, pageText: String?) -> String? {
        guard let host = url.host(), host == "amazon.com" || host.hasSuffix(".amazon.com") else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "openid.oa2.authorization_code" }?.value
        return code?.isEmpty == false ? code : nil
    }

    func finishSignIn(code: String) async throws -> String {
        guard let login = pending.get(), let client = login["client_id"], let verifier = login["code_verifier"],
              let serial = login["serial"] else {
            throw StoreError.failed(String(localized: "The Amazon sign-in took too long. Try again."))
        }
        pending.set(nil)
        _ = try await nile(["register", "--code", code, "--client-id", client, "--code-verifier", verifier, "--serial", serial])
        guard let user = try await context.secrets.secret(.amazon)?.files["nile/current_user.json"],
              let json = try? JSONSerialization.jsonObject(with: user) as? [String: Any] else {
            throw StoreError.failed(String(localized: "Amazon did not accept the sign-in. Try again."))
        }
        return json["name"] as? String ?? ""
    }

    func signOut() async throws {
        _ = try await nile(["auth", "--logout"])
    }

    func isExpired(_ secret: StoreSecret, now: Date) -> Bool { false }

    func library() async throws -> [StoreGame] {
        _ = try await checked(["library", "sync"])
        let output = try await checked(["library", "list", "--json"])
        guard let list = StoreJSON.array(output.stdout) else {
            throw StoreError.failed(String(localized: "nile returned a library Cartouche couldn’t read."))
        }
        return list.compactMap { $0 as? [String: Any] }.compactMap(Self.game)
    }

    static func game(_ json: [String: Any]) -> StoreGame? {
        guard let product = json["product"] as? [String: Any], let id = product["id"] as? String,
              let title = product["title"] as? String else { return nil }
        let detail = product["productDetail"] as? [String: Any]
        let icon = (detail?["iconUrl"] as? String) ?? ((detail?["details"] as? [String: Any])?["logoUrl"] as? String)
        return StoreGame(id: id, title: title, art: icon.flatMap(URL.init(string:)))
    }

    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        _ = try await checked(["install", game.id, "--base-path", base.clientPath], progress: progress)
        return try installed(game.id)
    }

    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        _ = try await checked(["update", id, "--path", install.path.clientPath], progress: progress)
        return try installed(id)
    }

    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await checked(["verify", id, "--path", install.path.clientPath], progress: progress)
    }

    func uninstall(_ id: String, install: StoreInstall) async throws {
        _ = try await checked(["uninstall", id])
    }

    // An Amazon game folder carries fuel.json but not its product ID: the folder
    // name is matched to a title of the library
    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall) {
        guard FileManager.default.fileExists(atPath: folder.appending(path: "fuel.json").path(percentEncoded: false)),
              let game = Self.match(folder.lastPathComponent, in: library) else {
            throw StoreError.unknownGame(folder.lastPathComponent)
        }
        _ = try await checked(["import", "--path", folder.clientPath, game.id])
        return (game, try installed(game.id))
    }

    static func match(_ folderName: String, in library: [StoreGame]) -> StoreGame? {
        let key = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = key(folderName)
        return library.first { key($0.title) == wanted }
    }

    // nile's installed.json: [{"id", "version", "path"}]
    private func installed(_ id: String) throws -> StoreInstall {
        let file = context.folder.appending(path: "nile/installed.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = list.first(where: { $0["id"] as? String == id }), let path = entry["path"] as? String else {
            throw StoreError.failed(String(localized: "nile did not report where the game was installed."))
        }
        return StoreInstall(path: URL(filePath: path, directoryHint: .isDirectory), version: entry["version"] as? String)
    }

    // fuel.json, which the Amazon Games app reads too; nile needs no sign-in to start a game
    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch {
        guard let data = try? Data(contentsOf: install.path.appending(path: "fuel.json")),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let main = json["Main"] as? [String: Any], let command = main["Command"] as? String else {
            throw StoreError.failed(String(localized: "The game’s fuel.json file is missing. Verify its files."))
        }
        let exe = PrefixPaths.join(install.path, command)
        let working = (main["WorkingSubdirOverride"] as? String).map { PrefixPaths.join(install.path, $0) }
            ?? exe.deletingLastPathComponent()
        return StoreLaunch(executable: exe, arguments: main["Args"] as? [String] ?? [], workingDirectory: working)
    }

    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation] { [] }

    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String] {
        stamps
    }

    // MARK: Running nile

    private func nile(_ arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        try await context.run(.nile, store: .amazon, arguments) { line in
            if let fraction = ClientProgress.fraction(line) { progress?(fraction) }
        }
    }

    private func checked(_ arguments: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClientOutput {
        let output = try await nile(arguments, progress: progress)
        if ["User not logged in", "Failed to refresh the token"].contains(where: output.stderr.contains) {
            throw StoreError.sessionExpired
        }
        guard output.succeeded else {
            throw StoreError.failed(ClientLog.lastError(output.stderr) ?? String(localized: "nile stopped with status \(output.status)."))
        }
        return output
    }
}
