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

public struct KeychainSecrets: SecretStore {

    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, for account: String) throws {
        delete(account)
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        // Readable only on this Mac, after it is first unlocked; not synced
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
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
