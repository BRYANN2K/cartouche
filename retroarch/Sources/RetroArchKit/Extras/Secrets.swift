import Foundation
import Security
import Synchronization

// Where a token is kept. The app keeps it in the login keychain; tests keep it in memory, so they never add an item to the user's keychain.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ secret: String, for account: String) throws
    func delete(_ account: String)
}

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

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

    // The data protection keychain: per-app items, no login-keychain ACL prompts. A build signed
    // without an application identifier (ad hoc) lacks its entitlement and stays on the login keychain.
    public static func protected(_ query: [String: Any]) -> [String: Any] {
        query.merging([kSecUseDataProtectionKeychain as String: true]) { $1 }
    }

    static func unentitled(_ error: Error) -> Bool {
        (error as? SecretStoreError) == .keychain(errSecMissingEntitlement)
    }

    // A login-keychain item is copied to the data protection keychain once; it is removed only after the copy reads back.
    public static func readMigrating(_ query: [String: Any], attributes: [String: Any]) throws -> Data? {
        try migrate(modern: { try read(protected(query)) },
                    legacy: { try read(query) },
                    store: { try write($0, matching: protected(query), attributes: attributes) },
                    dropLegacy: { try delete(query) })
    }

    static func migrate(modern: () throws -> Data?, legacy: () throws -> Data?,
                        store: (Data) throws -> Void, dropLegacy: () throws -> Void) throws -> Data? {
        do {
            if let data = try modern() { return data }
        } catch let error where unentitled(error) {
            return try legacy()
        }
        guard let data = try legacy() else { return nil }
        do {
            try store(data)
            if try modern() == data { try? dropLegacy() }
        } catch {
            // The legacy item stays; the next read tries again
        }
        return data
    }

    public static func writeProtected(_ data: Data, matching query: [String: Any], attributes: [String: Any]) throws {
        do {
            try write(data, matching: protected(query), attributes: attributes)
        } catch let error where unentitled(error) {
            try write(data, matching: query, attributes: attributes)
            return
        }
        // An older login-keychain copy would otherwise come back once this one is deleted
        try? delete(query)
    }

    public static func deleteEverywhere(_ query: [String: Any]) throws {
        do {
            try delete(protected(query))
        } catch let error where unentitled(error) {
        }
        try delete(query)
    }
}

public struct KeychainSecrets: SecretStore {

    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    // Readable only on this Mac, after it is first unlocked; not synced
    private static var attributes: [String: Any] { [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] }

    public func read(_ account: String) -> String? {
        (try? Keychain.readMigrating(query(account), attributes: Self.attributes)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func write(_ secret: String, for account: String) throws {
        try Keychain.writeProtected(Data(secret.utf8), matching: query(account), attributes: Self.attributes)
    }

    public func delete(_ account: String) {
        try? Keychain.deleteEverywhere(query(account))
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
