// A shared fix is applied only after its registry and artifact check out against a key shipped with the app.
// The key embedded in a downloaded artifact is never trusted. Nothing in a fix's text is executed.

import CryptoKit
import Foundation
import RetroArchKit

struct TrustedFixKeys: Sendable {
    let keys: [String: Curve25519.Signing.PublicKey]

    static let infoKey = "CartoucheFixKeys"

    // Info.plist: CartoucheFixKeys = { key id: base64 raw Ed25519 public key }. Absent until a signing key exists.
    static func bundled(_ bundle: Bundle = .main) -> TrustedFixKeys {
        let raw = bundle.object(forInfoDictionaryKey: infoKey) as? [String: String] ?? [:]
        return TrustedFixKeys(keys: raw.compactMapValues {
            Data(base64Encoded: $0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        })
    }
}

struct VerifiedRegistry: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let id: String
        let revision: Int
        let sha256: String
    }

    let version: Int
    let expires: Date
    let fixes: [Entry]
    let revoked: Set<String>

    func isRevoked(_ id: String, _ revision: Int) -> Bool { revoked.contains("\(id)#\(revision)") }
}

struct VerifiedFix: Equatable, Sendable {
    let id: String
    let revision: Int
    let gameID: String
    let recipe: ContributionWire.Recipe
}

enum FixVerifier {

    enum Refusal: Error, Equatable, Sendable {
        case noTrustedKey
        case unknownKey
        case badSignature
        case expired
        case rolledBack
        case notListed
        case hashMismatch
        case revoked
        case otherGame
        case unsupported
    }

    static func verified(_ envelope: JSONValue, keys: TrustedFixKeys) throws(Refusal) -> JSONValue {
        guard !keys.keys.isEmpty else { throw .noTrustedKey }
        guard envelope["algorithm"]?.string == "Ed25519", let id = envelope["key_id"]?.string else { throw .badSignature }
        guard let key = keys.keys[id] else { throw .unknownKey }
        guard let payload = envelope["payload"], let text = envelope["signature"]?.string,
              let signature = Data(base64Encoded: text),
              key.isValidSignature(signature, for: CanonicalJSON.data(payload))
        else { throw .badSignature }
        return payload
    }

    static func registry(_ data: Data, keys: TrustedFixKeys, now: Date, lastVersion: Int) throws(Refusal) -> VerifiedRegistry {
        guard let envelope = try? CanonicalJSON.parse(data) else { throw .badSignature }
        let payload = try verified(envelope, keys: keys)
        guard payload["schema_version"]?.int == 1, let version = payload["version"]?.int,
              let expiresText = payload["expires_at"]?.string, let expires = ContributionAdapter.date(expiresText)
        else { throw .unsupported }
        guard now < expires else { throw .expired }
        guard version >= lastVersion else { throw .rolledBack }
        let fixes = (payload["fixes"]?.array ?? []).compactMap { e -> VerifiedRegistry.Entry? in
            guard let id = e["id"]?.string, let r = e["revision"]?.int, let h = e["sha256"]?.string else { return nil }
            return VerifiedRegistry.Entry(id: id, revision: r, sha256: h.lowercased())
        }
        let revoked = Set((payload["revoked"]?.array ?? []).compactMap { e -> String? in
            guard let id = e["id"]?.string, let r = e["revision"]?.int else { return nil }
            return "\(id)#\(r)"
        })
        return VerifiedRegistry(version: version, expires: expires, fixes: fixes, revoked: revoked)
    }

    static func artifact(_ data: Data, registry: VerifiedRegistry, keys: TrustedFixKeys, gameID: String, now: Date)
        throws(Refusal) -> VerifiedFix
    {
        guard now < registry.expires else { throw .expired }
        guard let envelope = try? CanonicalJSON.parse(data) else { throw .badSignature }
        let payload = try verified(envelope, keys: keys)
        guard let id = payload["id"]?.string, let revision = payload["revision"]?.int else { throw .unsupported }
        guard !registry.isRevoked(id, revision) else { throw .revoked }
        guard let entry = registry.fixes.first(where: { $0.id == id && $0.revision == revision }) else { throw .notListed }
        let digest = SHA256.hash(data: CanonicalJSON.data(envelope)).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else { throw .hashMismatch }
        guard payload["game_id"]?.string == gameID else { throw .otherGame }
        guard payload["schema_version"]?.int == 1, let recipeValue = payload["recipe"],
              let recipe = try? JSONDecoder().decode(ContributionWire.Recipe.self, from: CanonicalJSON.data(recipeValue)),
              recipe.schemaVersion == 1, recipe.appliesTo.platform == "macos",
              recipe.operations.allSatisfy({ $0.type == "set_game_config" && !$0.values.isEmpty }),
              recipe.requires.isEmpty
        else { throw .unsupported }
        return VerifiedFix(id: id, revision: revision, gameID: gameID, recipe: recipe)
    }
}

// What a verified fix would change in the game's setup, and whether it fits this Mac's setup
struct FixPlan: Equatable, Sendable {

    enum Mismatch: Equatable, Sendable {
        case runner
        case backend
        case gameBuild
        case unknownGameBuild
        case backendNotOffered
        case macVersion
    }

    struct Change: Equatable, Sendable, Identifiable {
        let setting: String
        let from: String
        let to: String
        var id: String { setting }
    }

    let before: GameSetupChoice
    let after: GameSetupChoice
    let changes: [Change]
    let mismatches: [Mismatch]

    var canApply: Bool { mismatches.isEmpty && !changes.isEmpty }

    static func make(_ fix: VerifiedFix, choice: GameSetupChoice, resolved: GameSetup, offered: [GraphicsBackend],
                     hasMacBuild: Bool, gameBuild: String?) -> FixPlan
    {
        var after = choice
        for op in fix.recipe.operations {
            if let raw = op.values.backend { after.graphics = GraphicsBackend(rawValue: raw) }
            if let raw = op.values.translation { after.translation = GameSetupChoice.Translation(rawValue: raw) }
            if let raw = op.values.version { after.version = GameVersion(rawValue: raw) }
            if let hud = op.values.metalHUD { after.metalHUD = hud }
        }
        let version = hasMacBuild ? (after.version ?? resolved.version) : .windows
        let native = version == .mac
        let backend = native ? "native" : (after.graphics ?? resolved.backend)?.rawValue ?? "other"
        let runner = native ? "native" : resolved.runner?.id ?? ""
        let applies = fix.recipe.appliesTo
        var mismatches: [Mismatch] = []
        if !applies.runnerBuilds.contains(runner) { mismatches.append(.runner) }
        if !applies.backends.contains(backend) { mismatches.append(.backend) }
        if !native, let wanted = after.graphics, !offered.contains(wanted) { mismatches.append(.backendNotOffered) }
        if after.version == .mac && !hasMacBuild { mismatches.append(.macVersion) }
        if !applies.gameBuilds.isEmpty {
            if let gameBuild {
                if !applies.gameBuilds.contains(gameBuild) { mismatches.append(.gameBuild) }
            } else {
                mismatches.append(.unknownGameBuild)
            }
        }
        var changes: [Change] = []
        let none = String(localized: "Default")
        if after.graphics != choice.graphics {
            changes.append(Change(setting: String(localized: "Graphics"), from: choice.graphics?.label ?? none, to: after.graphics?.label ?? none))
        }
        if after.translation != choice.translation {
            changes.append(Change(setting: String(localized: "Translation"), from: choice.translation?.label ?? none,
                                  to: after.translation?.label ?? none))
        }
        if after.version != choice.version {
            changes.append(Change(setting: String(localized: "Run"), from: choice.version?.label ?? none, to: after.version?.label ?? none))
        }
        if after.metalHUD != choice.metalHUD {
            let on = String(localized: "On"), off = String(localized: "Off")
            changes.append(Change(setting: "Metal HUD", from: (choice.metalHUD ?? false) ? on : off, to: (after.metalHUD ?? false) ? on : off))
        }
        return FixPlan(before: choice, after: after, changes: changes, mismatches: mismatches)
    }
}

// The setup saved before a fix, so Undo restores it exactly
struct AppliedFix: Codable, Equatable, Sendable {
    var gameID: String
    var fixID: String
    var revision: Int
    var title: String
    var previous: GameSetupChoice
    var applied: GameSetupChoice
    var at: Date
}

struct AppliedFixStore: Sendable {
    let file: URL

    static var standard: AppliedFixStore {
        AppliedFixStore(file: SupportPaths.support.appending(path: "community/applied-fixes.json"))
    }

    func load() -> [String: AppliedFix] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([String: AppliedFix].self, from: data)) ?? [:]
    }

    func save(_ all: [String: AppliedFix]) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(file, with: try e.encode(all), step: "applied fixes")
    }
}

enum FixApplication {

    // The backup is written before the setup changes; without it nothing is applied
    static func apply(_ plan: FixPlan, fix: VerifiedFix, gameID: String, store: AppliedFixStore, now: Date,
                      setSetup: (GameSetupChoice) -> Void) throws {
        var all = store.load()
        let previous = all[gameID]?.previous ?? plan.before
        all[gameID] = AppliedFix(gameID: gameID, fixID: fix.id, revision: fix.revision, title: fix.recipe.title,
                                 previous: previous, applied: plan.after, at: now)
        try store.save(all)
        setSetup(plan.after)
    }

    static func undo(gameID: String, store: AppliedFixStore, setSetup: (GameSetupChoice) -> Void) throws {
        var all = store.load()
        guard let record = all[gameID] else { return }
        setSetup(record.previous)
        all[gameID] = nil
        try store.save(all)
    }
}
