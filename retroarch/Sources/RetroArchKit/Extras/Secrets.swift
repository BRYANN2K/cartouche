import Foundation
import Security
import Synchronization

// Where a token is kept. The app keeps it in the login keychain; tests keep
// it in memory, so they never add an item to the user's keychain.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ secret: String, for account: String) throws
    func delete(_ account: String)
}

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

// The one SecItem dance both vaults share: read one item, update or add, delete
public enum Keychain {
    public static func read(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return item as? Data
    }

    // Updates in place so a rewrite never leaves the item missing
    public static func write(_ data: Data, matching query: [String: Any], attributes: [String: Any]) throws {
        var attributes = attributes
        attributes[kSecValueData as String] = data
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public static func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

public struct KeychainSecrets: SecretStore {

    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        (try? Keychain.read(query(account))).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func write(_ secret: String, for account: String) throws {
        // Readable only on this Mac, after it is first unlocked; not synced
        try Keychain.write(Data(secret.utf8), matching: query(account),
                           attributes: [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly])
    }

    public func delete(_ account: String) {
        try? Keychain.delete(query(account))
    }
}

public final class MemorySecrets: SecretStore {
    private let secrets = Mutex<[String: String]>([:])

    public init() {}

    public func read(_ account: String) -> String? { secrets.withLock { $0[account] } }
    public func write(_ secret: String, for account: String) throws { secrets.withLock { $0[account] = secret } }
    public func delete(_ account: String) { _ = secrets.withLock { $0.removeValue(forKey: account) } }

    public var all: [String: String] { secrets.withLock { $0 } }
}
