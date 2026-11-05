import Foundation
import Testing

@testable import NotProtonApp

// A SecretItem in memory, standing in for a Keychain item
final class MemoryItem: SecretItem, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    private(set) var deletes = 0
    var readError: (any Error)?
    var writeError: (any Error)?
    var deleteError: (any Error)?
    private var stored: Data?

    var data: Data? { lock.withLock { stored } }

    init(_ data: Data? = nil) { stored = data }

    func read() throws -> Data? {
        lock.withLock { reads += 1 }
        if let readError { throw readError }
        return lock.withLock { stored }
    }

    func write(_ data: Data) throws {
        if let writeError { throw writeError }
        lock.withLock { stored = data }
    }

    func delete() throws {
        lock.withLock { deletes += 1 }
        if let deleteError { throw deleteError }
        lock.withLock { stored = nil }
    }
}

@Suite("Store vault: one Keychain item for every store")
struct StoreVaultTests {

    private static func grouped(_ secrets: [GameSource: StoreSecret]) throws -> MemoryItem {
        MemoryItem(try JSONEncoder().encode(
            Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.id, $0.value) })))
    }

    private static func legacy(_ secret: StoreSecret) throws -> MemoryItem {
        MemoryItem(try JSONEncoder().encode(secret))
    }

    private static func secrets(_ item: MemoryItem) throws -> [String: StoreSecret] {
        try JSONDecoder().decode([String: StoreSecret].self, from: #require(item.data))
    }

    @Test("The shared item answers first and the per-store item is left alone")
    func groupedFirst() throws {
        let grouped = try Self.grouped([.gog: StoreSecret(account: "galaxy", files: [:])])
        let legacy = try Self.legacy(StoreSecret(account: "old", files: [:]))
        #expect(try KeychainVault.read(.gog, grouped: grouped, legacy: legacy)?.account == "galaxy")
        #expect(legacy.reads == 0)
    }

    @Test("A secret left in a per-store item moves into the shared one; the old item leaves only after the copy reads back")
    func migration() throws {
        let grouped = MemoryItem()
        let legacy = try Self.legacy(StoreSecret(account: "player42", files: ["user.json": Data("one".utf8)]))
        let secret = try KeychainVault.read(.epic, grouped: grouped, legacy: legacy)
        #expect(secret?.account == "player42")
        #expect(try Self.secrets(grouped)["epic"] == secret)
        #expect(legacy.data == nil && legacy.deletes == 1)
    }

    @Test("When the shared item cannot take the copy, the per-store item stays and the read still answers")
    func failedMigrationKeepsLegacy() throws {
        let grouped = MemoryItem()
        let legacy = try Self.legacy(StoreSecret(account: "Ana", files: [:]))
        grouped.writeError = StoreError.failed("locked")
        #expect(try KeychainVault.read(.amazon, grouped: grouped, legacy: legacy)?.account == "Ana")
        #expect(legacy.data != nil && legacy.deletes == 0)
        grouped.writeError = nil
        #expect(try KeychainVault.read(.amazon, grouped: grouped, legacy: legacy)?.account == "Ana")
        #expect(legacy.data == nil)
    }

    @Test("Writing one store keeps the others and clears that store's old item")
    func writeMerges() throws {
        let grouped = try Self.grouped([.gog: StoreSecret(account: "galaxy", files: ["auth.json": Data("1".utf8)])])
        let legacy = try Self.legacy(StoreSecret(account: "old", files: [:]))
        try KeychainVault.write(StoreSecret(account: "player42", files: [:]), for: .epic,
                              grouped: grouped, legacy: legacy)
        let all = try Self.secrets(grouped)
        #expect(all["gog"]?.account == "galaxy")
        #expect(all["epic"]?.account == "player42")
        #expect(legacy.data == nil)
    }

    @Test("Deleting a store removes only its entry, then the empty item; a stale per-store item is cleared too")
    func deleteStore() throws {
        let grouped = try Self.grouped([.epic: StoreSecret(account: "ep", files: [:]),
                                        .gog: StoreSecret(account: "gg", files: [:])])
        let stale = try Self.legacy(StoreSecret(account: "old", files: [:]))
        try KeychainVault.delete(.gog, grouped: grouped, legacy: stale)
        #expect(try Self.secrets(grouped)["gog"] == nil)
        #expect(try Self.secrets(grouped)["epic"] != nil)
        #expect(stale.data == nil)
        try KeychainVault.delete(.epic, grouped: grouped, legacy: MemoryItem())
        #expect(grouped.data == nil)
    }

    @Test("A shared item that does not decode fails instead of being overwritten")
    func corruptGroupedFailsClosed() throws {
        let grouped = MemoryItem(Data("not json".utf8))
        #expect(throws: (any Error).self) { try KeychainVault.read(.gog, grouped: grouped, legacy: MemoryItem()) }
        #expect(throws: (any Error).self) {
            try KeychainVault.write(StoreSecret(account: "x", files: [:]), for: .gog,
                                    grouped: grouped, legacy: MemoryItem())
        }
        #expect(grouped.data == Data("not json".utf8))
    }

    @Test("Nothing anywhere means the store is not signed in")
    func empty() throws {
        #expect(try KeychainVault.read(.gog, grouped: MemoryItem(), legacy: MemoryItem()) == nil)
    }
}
