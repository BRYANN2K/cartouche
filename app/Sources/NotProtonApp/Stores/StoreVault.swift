// Store sign-ins live in the Keychain and nowhere else. The clients keep their
// tokens in files, so those files are written into the client's own folder just
// before it runs, read back once the last run that needs them ends (a client may
// have refreshed them), and deleted. Cartouche never sees a password: only the
// tokens the store hands the client after the user signs in on the store's page.

import Foundation
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

    static let service = "dev.bryann2k.cartouche.store"

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
        var item: CFTypeRef?
        var query = query(store)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.failure(status) }
        return try JSONDecoder().decode(StoreSecret.self, from: data)
    }

    func write(_ secret: StoreSecret, for store: GameSource) throws {
        let data = try JSONEncoder().encode(secret)
        let update = SecItemUpdate(query(store) as CFDictionary, attributes(data) as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.failure(update) }
        let added = SecItemAdd(query(store).merging(attributes(data)) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.failure(added) }
    }

    func delete(_ store: GameSource) throws {
        let status = SecItemDelete(query(store) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
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

    // Runs body with the store's token files in place. Signing in starts with none;
    // the account name of a new sign-in comes from the body's result.
    func using<T: Sendable>(_ store: GameSource, account: String? = nil,
                            _ body: @Sendable () async throws -> T) async throws -> T {
        try open(store, account: account)
        do {
            let result = try await body()
            try close(store)
            return result
        } catch {
            try? close(store)
            throw error
        }
    }

    func setAccount(_ name: String, for store: GameSource) { accounts[store] = name }

    private func open(_ store: GameSource, account: String?) throws {
        if let account { accounts[store] = account }
        if users[store, default: 0] == 0 { try materialize(store) }
        users[store, default: 0] += 1
    }

    private func materialize(_ store: GameSource) throws {
        guard let folder = folders[store] else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let secret = try vault.read(store) else { return }
        if accounts[store] == nil { accounts[store] = secret.account }
        for (path, data) in secret.files where RunnerManifest.isInside(path) {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    private func close(_ store: GameSource) throws {
        users[store, default: 1] -= 1
        guard users[store] == 0 else { return }
        try collect(store)
    }

    // Puts whatever token files the client left back into the vault and deletes
    // them. With none left, the client signed out, and so does the vault.
    func collect(_ store: GameSource) throws {
        guard let folder = folders[store] else { return }
        let files = Self.files(in: folder, matching: patterns[store] ?? [])
        defer { for (_, url) in files { try? FileManager.default.removeItem(at: url) } }
        var contents: [String: Data] = [:]
        for (path, url) in files { contents[path] = try Data(contentsOf: url) }
        if contents.isEmpty {
            try vault.delete(store)
            accounts[store] = nil
        } else {
            let account = accounts[store] ?? (try? vault.read(store))?.account ?? ""
            try vault.write(StoreSecret(account: account, files: contents), for: store)
        }
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
