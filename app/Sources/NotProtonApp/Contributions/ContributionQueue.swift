// Contributions the user confirmed, kept on disk until the site has them. Transport and moderation are separate states.

import Foundation
import RetroArchKit

struct ContributionItem: Codable, Equatable, Identifiable, Sendable {

    enum Kind: String, Codable, Sendable {
        case report, reportRevision, reportWithdrawal, fix, fixRevision, fixWithdrawal
    }

    enum Transport: String, Codable, Sendable {
        case draft, confirmed, received, failed
    }

    enum Moderation: String, Codable, Sendable {
        case pending, published, rejected, withdrawn, revoked
    }

    var id = UUID()
    var kind: Kind
    var game: ContributionGame
    var summary: String
    var body: Data?
    var idempotencyKey: String?
    var transport = Transport.draft
    var moderation: Moderation?
    var reason: String?
    // The report or fix this operation is about, and the version it was read at
    var remoteID: String?
    var remoteVersion: Int?
    var remoteRevision: Int?
    var attempts = 0
    var nextAttempt: Date?
    var lastError: String?
    var created = Date()

    var isPending: Bool { transport == .confirmed }
    var canDelete: Bool { transport != .received || moderation == .withdrawn || moderation == .rejected || moderation == .revoked }
}

struct ContributionQueueFile: Sendable {

    let file: URL

    static var standard: ContributionQueueFile {
        ContributionQueueFile(file: SupportPaths.support.appending(path: "community/queue.json"))
    }

    func load() -> [ContributionItem] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ContributionItem].self, from: data)) ?? []
    }

    func save(_ items: [ContributionItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicReplace(file, with: try encoder.encode(items), step: "contributions")
    }
}

enum ContributionQueue {

    // The key is bound to the content: a resend of the same bytes reuses it, an edit makes a new operation
    static func confirm(_ item: inout ContributionItem) {
        guard item.transport == .draft || item.transport == .failed else { return }
        if item.idempotencyKey == nil {
            item.idempotencyKey = "cartouche-" + UUID().uuidString.lowercased()
        }
        item.transport = .confirmed
        item.attempts = 0
        item.nextAttempt = nil
        item.lastError = nil
    }

    static func edit(_ item: inout ContributionItem, body: Data, summary: String) {
        guard item.transport != .received else { return }
        if body != item.body {
            item.idempotencyKey = nil
            item.transport = .draft
        }
        item.body = body
        item.summary = summary
    }

    static func backoff(attempts: Int) -> TimeInterval {
        min(6 * 3600, 30 * pow(2, Double(max(0, attempts - 1))))
    }

    static func due(_ items: [ContributionItem], now: Date) -> [ContributionItem.ID] {
        items.filter { $0.isPending && ($0.nextAttempt ?? .distantPast) <= now }.map(\.id)
    }
}

// Sends one confirmed item. Never sends anything that was not confirmed, and never to another service.
struct ContributionSender: Sendable {

    enum Result: Equatable, Sendable {
        case received(ContributionItem)
        case later(ContributionItem)
        case failed(ContributionItem)
        case credentialRefused
        case stop
    }

    let client: ContributionClient

    func send(_ original: ContributionItem, token: String, now: Date,
              own: @Sendable () async -> (reports: [ContributionClient.OwnReport], fixes: [ContributionClient.OwnFix])?)
        async -> Result
    {
        var item = original
        guard item.transport == .confirmed else { return .stop }
        item.attempts += 1
        do throws(ContributionClient.Failure) {
            let accepted: ContributionClient.Accepted
            switch item.kind {
            case .report:
                accepted = try await client.submitReport(game: item.game.ref, body: item.body ?? Data(),
                                                         key: item.idempotencyKey ?? "", token: token)
            case .fix:
                accepted = try await client.proposeFix(game: item.game.ref, body: item.body ?? Data(),
                                                       key: item.idempotencyKey ?? "", token: token)
            case .fixRevision:
                accepted = try await client.reviseFix(id: item.remoteID ?? "", game: item.game.ref, recipe: item.body ?? Data(),
                                                      key: item.idempotencyKey ?? "", token: token)
            case .reportRevision:
                accepted = try await client.reviseReport(id: item.remoteID ?? "", version: item.remoteVersion ?? 0,
                                                         body: item.body ?? Data(), token: token)
            case .reportWithdrawal:
                accepted = try await client.withdrawReport(id: item.remoteID ?? "", version: item.remoteVersion ?? 0, token: token)
            case .fixWithdrawal:
                accepted = try await client.withdrawFix(id: item.remoteID ?? "", revision: item.remoteRevision ?? 0, token: token)
            }
            item.transport = .received
            item.remoteID = accepted.id
            item.remoteVersion = accepted.version ?? item.remoteVersion
            item.remoteRevision = accepted.revision ?? item.remoteRevision
            item.moderation = ContributionItem.Moderation(rawValue: accepted.status) ?? .pending
            item.lastError = nil
            item.nextAttempt = nil
            return .received(item)
        } catch {
            switch error {
            case .offline:
                item.lastError = "offline"
                item.nextAttempt = now.addingTimeInterval(ContributionQueue.backoff(attempts: item.attempts))
                return .later(item)
            case .retry(let after):
                item.lastError = "busy"
                item.nextAttempt = now.addingTimeInterval(max(after ?? 0, ContributionQueue.backoff(attempts: item.attempts)))
                return .later(item)
            case .unauthorized:
                item.attempts -= 1
                return .credentialRefused
            case .conflict(let code):
                // A replayed revision or withdrawal the server already applied answers with a version conflict
                if let settled = await settled(item, own: own) { return .received(settled) }
                item.transport = .failed
                item.lastError = code
                return .failed(item)
            case .notFound(let code):
                if code == "game_not_found", item.kind == .report || item.kind == .fix {
                    try? await client.proposeGame(item.game, token: token)
                    item.lastError = code
                    item.nextAttempt = now.addingTimeInterval(24 * 3600)
                    return .later(item)
                }
                item.transport = .failed
                item.lastError = code
                return .failed(item)
            case .rejected(let code):
                item.transport = .failed
                item.lastError = code
                return .failed(item)
            }
        }
    }

    private func settled(
        _ item: ContributionItem,
        own: @Sendable () async -> (reports: [ContributionClient.OwnReport], fixes: [ContributionClient.OwnFix])?
    ) async -> ContributionItem? {
        guard let id = item.remoteID, let own = await own() else { return nil }
        var out = item
        out.transport = .received
        out.lastError = nil
        switch item.kind {
        case .reportWithdrawal:
            guard let r = own.reports.first(where: { $0.id == id }), r.status == "withdrawn" else { return nil }
            out.moderation = .withdrawn
            out.remoteVersion = r.version
        case .reportRevision:
            guard let r = own.reports.first(where: { $0.id == id }), r.version > (item.remoteVersion ?? 0),
                  let body = item.body, let mine = try? CanonicalJSON.parse(body), r.payload.map(CanonicalJSON.string) == CanonicalJSON.string(mine)
            else { return nil }
            out.moderation = ContributionItem.Moderation(rawValue: r.status) ?? .pending
            out.remoteVersion = r.version
        case .fixWithdrawal:
            guard let rev = own.fixes.first(where: { $0.id == id })?.revisions.first(where: { $0.revision == item.remoteRevision }),
                  rev.status == "withdrawn" || rev.status == "revoked"
            else { return nil }
            out.moderation = ContributionItem.Moderation(rawValue: rev.status)
        default:
            return nil
        }
        return out
    }
}
