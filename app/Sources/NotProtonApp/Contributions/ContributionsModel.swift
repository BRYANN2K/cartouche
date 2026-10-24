// Sharing results and fixes with the Cartouche site, and using the fixes others shared. Everything is sent by hand:
// a contribution leaves the Mac only after the user confirmed its preview.

import Foundation
import Observation
import RetroArchKit

@MainActor
@Observable
final class ContributionsModel {

    private(set) var items: [ContributionItem] = []
    private(set) var ownReports: [ContributionClient.OwnReport] = []
    private(set) var ownFixes: [ContributionClient.OwnFix] = []
    private(set) var applied: [String: AppliedFix] = [:]
    private(set) var problem: String?
    private(set) var credentialUnsaved = false
    private(set) var isSending = false

    @ObservationIgnored let client: ContributionClient?
    @ObservationIgnored let queue: ContributionQueueFile
    @ObservationIgnored let identity: ContributorIdentity?
    @ObservationIgnored let appliedStore: AppliedFixStore
    @ObservationIgnored let keys: TrustedFixKeys
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored var mac: @Sendable () -> MacInfo = { MacInfo.current() }
    @ObservationIgnored var gameBuild: @Sendable (Game) -> String? = { game in
        guard game.source == .steam, let appID = game.steamAppID else { return nil }
        return SteamLocalFiles().manifests().first { $0.appID == appID }?.state["buildid"]?.string
    }
    @ObservationIgnored private var registryCache: VerifiedRegistry?

    static let identityKey = "community.confirmedIdentity."
    static let registryVersionKey = "community.fixRegistryVersion"

    init(client: ContributionClient? = CommunityService.baseURL().map { ContributionClient(base: $0) },
         queue: ContributionQueueFile = .standard, store: (any ContributorStore)? = nil,
         appliedStore: AppliedFixStore = .standard, keys: TrustedFixKeys = .bundled(), defaults: UserDefaults = .standard)
    {
        self.client = client
        self.queue = queue
        self.appliedStore = appliedStore
        self.keys = keys
        self.defaults = defaults
        identity = client.map { ContributorIdentity(store: store ?? KeychainContributorStore(base: $0.base)) }
        items = queue.load().map { item in
            var item = item
            item.nextAttempt = nil
            return item
        }
        applied = appliedStore.load()
    }

    var isAvailable: Bool { client != nil }

    // MARK: Identity

    func identity(for game: Game) -> ContributionGame.Resolution {
        let resolved = ContributionGame.resolve(game)
        if case .needsConfirmation(let candidate) = resolved, defaults.string(forKey: Self.identityKey + game.id) == candidate.ref {
            return .exact(candidate)
        }
        return resolved
    }

    func confirmIdentity(_ candidate: ContributionGame, for game: Game) {
        defaults.set(candidate.ref, forKey: Self.identityKey + game.id)
    }

    // MARK: Drafts

    func reportDraft(for game: Game, identity: ContributionGame, session: StoredSession?, library: LibraryModel,
                     resolved: ResolvedCompatibility, excludedSeconds: Int?) -> ReportDraft {
        var draft: ReportDraft
        if let session {
            draft = ReportDraft.from(session: session, game: identity, excludedSeconds: excludedSeconds)
        } else {
            let setup = library.resolution(for: game).setup
            let native = setup.version == .mac && library.hasMacBuild(game)
            draft = ReportDraft(game: identity, method: native ? .native : .wine,
                                runner: setup.runner.map { "\($0.kind.name) \($0.displayVersion)" }, runnerBuild: setup.runner?.id,
                                translation: setup.translation, backend: setup.backend, gameBuild: gameBuild(game),
                                observedAt: now())
        }
        draft.antiCheatNames = resolved.antiCheatNames
        if resolved.hasAntiCheat { draft.antiCheat = ContributionWire.AntiCheat(mode: .protectedMatchmaking, result: .notTested, names: []) }
        if let fix = applied[game.id] { draft.appliedFixes = [ContributionWire.AppliedFix(id: fix.fixID, revision: fix.revision)] }
        return draft
    }

    func reportBody(_ draft: ReportDraft) -> Data? {
        try? ContributionWire.encode(ContributionAdapter.report(draft, mac: mac(), appVersion: AppVersion.bundled))
    }

    func fixDraft(for game: Game, identity: ContributionGame, library: LibraryModel) -> FixDraft {
        FixDraft.from(setup: library.resolution(for: game).setup, game: identity, hasMacBuild: library.hasMacBuild(game),
                      gameBuild: gameBuild(game))
    }

    // MARK: Queue

    @discardableResult
    func add(_ kind: ContributionItem.Kind, game: ContributionGame, summary: String, body: Data?, confirm: Bool,
             remoteID: String? = nil, version: Int? = nil, revision: Int? = nil) -> ContributionItem {
        var item = ContributionItem(kind: kind, game: game, summary: summary, body: body, remoteID: remoteID,
                                    remoteVersion: version, remoteRevision: revision, created: now())
        if confirm { ContributionQueue.confirm(&item) }
        items.append(item)
        persist()
        if confirm { Task { await drain() } }
        return item
    }

    func update(_ id: ContributionItem.ID, body: Data, summary: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        ContributionQueue.edit(&items[i], body: body, summary: summary)
        persist()
    }

    func confirm(_ id: ContributionItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        ContributionQueue.confirm(&items[i])
        persist()
        Task { await drain() }
    }

    // A draft or an operation the site has not received leaves without a trace; a received one stays for its status
    func remove(_ id: ContributionItem.ID) {
        guard let item = items.first(where: { $0.id == id }), item.transport != .received || item.canDelete else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do { try queue.save(items) } catch { problem = String(localized: "Cartouche couldn’t save your contributions: \(error.localizedDescription)") }
    }

    func drain() async {
        guard let client, let identity, !isSending else { return }
        isSending = true
        defer { isSending = false }
        let sender = ContributionSender(client: client)
        var retried = false
        while let id = ContributionQueue.due(items, now: now()).first {
            let credential: ContributionClient.Credential
            do {
                credential = try await identity.credential(client: client, now: now())
            } catch {
                problem = Self.message(error)
                return
            }
            credentialUnsaved = await identity.isUnsaved
            guard let item = items.first(where: { $0.id == id }) else { continue }
            let result = await sender.send(item, token: credential.token, now: now()) { [client] in
                guard let reports = try? await client.ownReports(token: credential.token),
                      let fixes = try? await client.ownFixes(token: credential.token) else { return nil }
                return (reports, fixes)
            }
            switch result {
            case .received(let next), .failed(let next), .later(let next):
                if let i = items.firstIndex(where: { $0.id == id }) { items[i] = next }
                persist()
            case .credentialRefused:
                guard !retried, await identity.refused(credential) else {
                    problem = String(localized: "The Cartouche site refused this Mac’s contributor key.")
                    return
                }
                retried = true
            case .stop:
                return
            }
        }
        problem = nil
    }

    static func message(_ error: ContributorIdentity.Problem) -> String {
        switch error {
        case .keychainUnreadable: String(localized: "Cartouche couldn’t read its contributor key from the Keychain.")
        case .waiting: String(localized: "Waiting before asking the Cartouche site for a contributor key again.")
        case .client: String(localized: "The Cartouche site can’t be reached. Your contributions wait on this Mac.")
        }
    }

    // MARK: Status

    func refreshOwn() async {
        guard let client, let identity else { return }
        guard let credential = try? await identity.credential(client: client, now: now()) else { return }
        guard let reports = try? await client.ownReports(token: credential.token),
              let fixes = try? await client.ownFixes(token: credential.token) else { return }
        ownReports = reports
        ownFixes = fixes
        for i in items.indices where items[i].transport == .received {
            guard let remote = items[i].remoteID else { continue }
            switch items[i].kind {
            case .report, .reportRevision, .reportWithdrawal:
                if let r = reports.first(where: { $0.id == remote }) {
                    items[i].moderation = ContributionItem.Moderation(rawValue: r.status)
                    items[i].reason = r.moderationReason
                    items[i].remoteVersion = r.version
                }
            case .fix, .fixRevision, .fixWithdrawal:
                if let rev = fixes.first(where: { $0.id == remote })?.revisions.first(where: { $0.revision == items[i].remoteRevision }) {
                    items[i].moderation = ContributionItem.Moderation(rawValue: rev.status)
                    items[i].reason = rev.moderationReason
                }
            }
        }
        persist()
    }

    func reports(for game: ContributionGame) -> [ContributionItem] {
        items.filter { $0.game == game && $0.kind == .report && $0.transport == .received && $0.remoteID != nil }
    }

    // MARK: Using a shared fix

    enum FixLoad: Equatable {
        case ready(VerifiedFix, FixPlan)
        case refused(FixVerifier.Refusal)
        case unavailable
    }

    func loadFix(_ ref: CommunityFeed.FixRef, game: Game, feedGameID: String, library: LibraryModel) async -> FixLoad {
        guard let client else { return .unavailable }
        do {
            let registry = try await registry(client: client)
            guard let data = try? await client.fixArtifact(id: ref.id, revision: ref.revision) else { return .unavailable }
            let fix = try FixVerifier.artifact(data, registry: registry, keys: keys, gameID: feedGameID, now: now())
            let resolution = library.resolution(for: game)
            let plan = FixPlan.make(fix, choice: library.setup(for: game.id), resolved: resolution.setup,
                                    offered: library.graphicsChoices(for: game), hasMacBuild: library.hasMacBuild(game),
                                    gameBuild: gameBuild(game))
            return .ready(fix, plan)
        } catch let refusal as FixVerifier.Refusal {
            return .refused(refusal)
        } catch {
            return .unavailable
        }
    }

    // A registry past its expiry is not enough to apply a fix, even offline
    private func registry(client: ContributionClient) async throws -> VerifiedRegistry {
        if let cached = registryCache, now() < cached.expires { return cached }
        let data: Data
        do { data = try await client.fixRegistry() } catch { throw FixVerifier.Refusal.expired }
        let last = defaults.integer(forKey: Self.registryVersionKey)
        let registry = try FixVerifier.registry(data, keys: keys, now: now(), lastVersion: last)
        defaults.set(registry.version, forKey: Self.registryVersionKey)
        registryCache = registry
        return registry
    }

    func apply(_ plan: FixPlan, fix: VerifiedFix, game: Game, library: LibraryModel) {
        do {
            try FixApplication.apply(plan, fix: fix, gameID: game.id, store: appliedStore, now: now()) {
                library.setSetup($0, for: game.id)
            }
            applied = appliedStore.load()
        } catch {
            problem = String(localized: "Cartouche couldn’t save your current setup, so the fix was not applied.")
        }
    }

    func undo(game: Game, library: LibraryModel) {
        do {
            try FixApplication.undo(gameID: game.id, store: appliedStore) { library.setSetup($0, for: game.id) }
            applied = appliedStore.load()
        } catch {
            problem = String(localized: "Cartouche couldn’t update its list of applied fixes.")
        }
    }

    static func refusal(_ r: FixVerifier.Refusal) -> String {
        switch r {
        case .noTrustedKey, .unknownKey: String(localized: "This version of Cartouche has no key to check shared fixes.")
        case .badSignature, .hashMismatch: String(localized: "The fix’s signature doesn’t match. It was not applied.")
        case .expired: String(localized: "The list of valid fixes is out of date. Connect to the internet to check it again.")
        case .rolledBack: String(localized: "The list of valid fixes is older than one already checked.")
        case .notListed, .revoked: String(localized: "This fix was withdrawn.")
        case .otherGame: String(localized: "This fix is for another game.")
        case .unsupported: String(localized: "This fix uses a format this version of Cartouche can’t apply.")
        }
    }
}
