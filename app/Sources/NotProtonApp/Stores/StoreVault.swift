// Store sign-ins live in the Keychain and nowhere else. The clients keep their
// tokens in files, so those files are written into the client's own folder just
// before it runs, read back once the last run that needs them ends (a client may
// have refreshed them), and deleted. Cartouche never sees a password: only the
// tokens the store hands the client after the user signs in on the store's page.

import Foundation
import RetroArchKit
import Security

// What the Keychain holds for one store: the client's token files and the account name
struct StoreSecret: Codable, Sendable, Equatable {
    var account: String
    // Path inside the client's folder to the file's bytes
    var files: [String: Data]
}

protocol TokenVault: Sendable {
    func read(_ store: GameSource) throws -> StoreSecret?
    func write(_ secret: StoreSecret, for store: GameSource) throws
    func delete(_ store: GameSource) throws
}

// One generic password per store, readable only while the Mac is unlocked and
// never synced to other devices
struct KeychainVault: TokenVault {

    // QA sign-ins use their own service so the real Keychain items are never read
    static var service: String {
        QAEnvironment.isActive ? "dev.bryann2k.cartouche.store.qa" : "dev.bryann2k.cartouche.store"
    }

    var service = KeychainVault.service

    func query(_ store: GameSource) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: store.id]
    }

    func attributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
         kSecAttrLabel as String: "Cartouche store sign-in"]
    }

    func read(_ store: GameSource) throws -> StoreSecret? {
        let data = try run { try Keychain.read(query(store)) }
        guard let data else { return nil }
        return try JSONDecoder().decode(StoreSecret.self, from: data)
    }

    func write(_ secret: StoreSecret, for store: GameSource) throws {
        let data = try JSONEncoder().encode(secret)
        try run { try Keychain.write(data, matching: query(store), attributes: attributes(data)) }
    }

    func delete(_ store: GameSource) throws {
        try run { try Keychain.delete(query(store)) }
    }

    private func run<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch SecretStoreError.keychain(let status) { throw Self.failure(status) }
    }

    static func failure(_ status: OSStatus) -> StepFailure {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        return StepFailure(step: String(localized: "Use the Keychain"), detail: reason)
    }
}

// Writes a store's token files for the clients and takes them back. Runs that
// overlap share one copy; the last one to end puts it back in the vault.
actor StoreSecrets {

    let vault: any TokenVault
    // The folder each store's client reads its tokens from
    let folders: [GameSource: URL]
    // The token files of each store, as paths or "*.ext" patterns inside its folder
    let patterns: [GameSource: [String]]

    private var users: [GameSource: Int] = [:]
    private var accounts: [GameSource: String] = [:]

    init(vault: any TokenVault, folders: [GameSource: URL], patterns: [GameSource: [String]]) {
        self.vault = vault
        self.folders = folders
        self.patterns = patterns
    }

    func secret(_ store: GameSource) throws -> StoreSecret? { try vault.read(store) }

    // Runs body with the store's token files in place. `fresh` starts the client
    // from an empty folder instead of the vault's copy — a sign-in (nile refuses
    // to register over a saved token) — and a failed body then leaves the vault's
    // older session alone. The account name of a new sign-in comes from the body's
    // result.
    func using<T: Sendable>(_ store: GameSource, account: String? = nil, fresh: Bool = false,
                            _ body: @Sendable () async throws -> T) async throws -> T {
        try open(store, account: account, fresh: fresh)
        do {
            let result = try await body()
            do {
                try close(store, collect: true)
            } catch {
                // The Keychain can be unreachable on a locked Mac; the files stay
                // (0600) and sweep() picks them up at the next start.
                AppLog.note("store \(store.id): tokens could not be stored: \(error.localizedDescription)")
            }
            return result
        } catch {
            try? close(store, collect: !fresh)
            throw error
        }
    }

    func setAccount(_ name: String, for store: GameSource) { accounts[store] = name }

    private func open(_ store: GameSource, account: String?, fresh: Bool) throws {
        if let account { accounts[store] = account }
        if users[store, default: 0] == 0 {
            guard let folder = folders[store] else { users[store] = 1; return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if fresh { clearFiles(store) } else { try materialize(store, in: folder) }
        }
        users[store, default: 0] += 1
    }

    private func materialize(_ store: GameSource, in folder: URL) throws {
        guard let secret = try vault.read(store) else { return }
        if accounts[store] == nil { accounts[store] = secret.account }
        for (path, data) in secret.files where RunnerManifest.isInside(path) {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    private func close(_ store: GameSource, collect: Bool) throws {
        users[store, default: 1] -= 1
        guard users[store] == 0 else { return }
        if collect { try self.collect(store) } else { clearFiles(store) }
    }

    // Deletes the token files a client was given; the vault keeps its copy.
    func clearFiles(_ store: GameSource) {
        guard let folder = folders[store] else { return }
        for (_, url) in Self.files(in: folder, matching: patterns[store] ?? []) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // Puts whatever token files the client left back into the vault. With none
    // left, the client signed out, and so does the vault. The files are deleted
    // only once the vault holds them.
    func collect(_ store: GameSource) throws {
        guard let folder = folders[store] else { return }
        let files = Self.files(in: folder, matching: patterns[store] ?? [])
        var contents: [String: Data] = [:]
        for (path, url) in files { contents[path] = try Data(contentsOf: url) }
        if contents.isEmpty {
            try vault.delete(store)
            accounts[store] = nil
        } else {
            let account = accounts[store] ?? (try? vault.read(store))?.account ?? ""
            try vault.write(StoreSecret(account: account, files: contents), for: store)
        }
        for (_, url) in files { try? FileManager.default.removeItem(at: url) }
    }

    // Token files a crash left on disk go back into the vault at the next start
    func sweep() {
        for store in folders.keys where (users[store] ?? 0) == 0 {
            guard let folder = folders[store], !Self.files(in: folder, matching: patterns[store] ?? []).isEmpty else { continue }
            try? collect(store)
        }
    }

    static func files(in folder: URL, matching patterns: [String]) -> [(String, URL)] {
        var out: [(String, URL)] = []
        let fm = FileManager.default
        for pattern in patterns {
            let parent = (pattern as NSString).deletingLastPathComponent
            let name = (pattern as NSString).lastPathComponent
            let directory = parent.isEmpty ? folder : folder.appending(path: parent)
            if name.hasPrefix("*") {
                let suffix = String(name.dropFirst())
                let entries = (try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
                for entry in entries.sorted() where entry.hasSuffix(suffix) {
                    out.append((parent.isEmpty ? entry : "\(parent)/\(entry)", directory.appending(path: entry)))
                }
            } else if fm.fileExists(atPath: folder.appending(path: pattern).path(percentEncoded: false)) {
                out.append((pattern, folder.appending(path: pattern)))
            }
        }
        return out
    }
}

extension StoreSecrets {
    // Drops a store's tokens from the vault and from disk
    func forget(_ store: GameSource) throws {
        clearFiles(store)
        try vault.delete(store)
    }

    // Names the account of the tokens a sign-in just saved. With a run still open
    // (a GOG game keeping comet alive), the vault is left alone: that run's close
    // writes the files under this account.
    func remember(account: String, for store: GameSource) throws {
        setAccount(account, for: store)
        guard (users[store] ?? 0) == 0 else { return }
        guard var secret = try vault.read(store) else { throw StoreError.failed(String(localized: "The sign-in left no login token.")) }
        secret.account = account
        try vault.write(secret, for: store)
    }
}
