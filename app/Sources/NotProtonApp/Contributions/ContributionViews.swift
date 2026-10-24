import RetroArchKit
import SwiftUI

// The game panel's Cartouche community block: what the site says, the fixes others shared, and sharing
struct CommunityBlock: View {
    let game: Game
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    let contributions: ContributionsModel

    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case results, fix, mine
        case review(CommunityFeed.FixRef)

        var id: String {
            switch self {
            case .results: "results"
            case .fix: "fix"
            case .mine: "mine"
            case .review(let ref): "review-\(ref.id)-\(ref.revision)"
            }
        }
    }

    private var method: PlayMethod {
        model.hasMacBuild(game) && model.resolution(for: game).setup.version == .mac ? .native : .wine
    }

    var body: some View {
        let resolved = compat.resolved(game, method: method)
        PanelGroup(title: String(localized: "Cartouche Community")) {
            if let statement = resolved.statement {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statement.verdict.label).font(.system(size: 13, weight: .semibold))
                    Text(statement.source).font(.system(size: 12)).foregroundStyle(Glass.label2)
                    if let notes = statement.notes {
                        Text(notes).font(.system(size: 12)).foregroundStyle(Glass.label2).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(statement.exceptions, id: \.mode) { exception in
                        Text(verbatim: "\(exception.mode): \(exception.notes ?? exception.status)")
                            .font(.system(size: 11)).foregroundStyle(Glass.label3).fixedSize(horizontal: false, vertical: true)
                    }
                    if resolved.origin == .cartoucheCached {
                        Text("Last copy from the Cartouche site").font(.system(size: 11)).foregroundStyle(Color.orange)
                    }
                }
                Divider()
            }
            if resolved.hasAntiCheat {
                Label(antiCheatLine(resolved), systemImage: resolved.macOnline == .blocked ? "xmark.shield" : "shield")
                    .font(.system(size: 12)).foregroundStyle(Glass.label2)
                Divider()
            }
            if let fix = contributions.applied[game.id] {
                HStack {
                    Text("Fix in use: \(fix.title)").font(.system(size: 12))
                    Spacer()
                    Button("Undo Fix") { contributions.undo(game: game, library: model) }.buttonStyle(.pill).controlSize(.small)
                }
                Divider()
            }
            ForEach(resolved.fixes, id: \.self) { ref in
                HStack {
                    Text("Shared fix, revision \(ref.revision)").font(.system(size: 12))
                    Spacer()
                    Button("Review…") { sheet = .review(ref) }.buttonStyle(.pill).controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Button("Share My Results…") { sheet = .results }.buttonStyle(.pill)
                Button("Share a Fix…") { sheet = .fix }.buttonStyle(.pill)
                Spacer()
                Button("My Contributions") { sheet = .mine }.buttonStyle(.pill)
            }
            if let problem = contributions.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .results: ShareResultsSheet(game: game, model: model, compat: compat, contributions: contributions, method: method)
            case .fix: ShareFixSheet(game: game, model: model, contributions: contributions)
            case .mine: MyContributionsSheet(contributions: contributions)
            case .review(let ref):
                FixReviewSheet(game: game, ref: ref, feedGameID: resolved.feedGameID ?? "", model: model, contributions: contributions)
            }
        }
    }

    private func antiCheatLine(_ r: ResolvedCompatibility) -> String {
        let names = ListFormatter.localizedString(byJoining: r.antiCheatNames)
        switch r.macOnline {
        case .compatible: return String(localized: "\(names): protected online play reported working on Mac")
        case .blocked: return String(localized: "\(names): protected online play blocked on Mac")
        case .unknown: return String(localized: "\(names): protected online play not reported on Mac")
        }
    }
}

// Asks the user which store game this is when only a title match links it to Steam
private struct IdentityRow: View {
    let game: Game
    let contributions: ContributionsModel
    @Binding var identity: ContributionGame?

    var body: some View {
        switch contributions.identity(for: game) {
        case .exact(let g):
            LabeledContent("Game") { Text(verbatim: "\(g.title) · \(g.ref)") }
                .onAppear { identity = g }
        case .needsConfirmation(let candidate):
            VStack(alignment: .leading, spacing: 6) {
                Text("Is this the Steam game with app ID \(candidate.storeID)? Cartouche matched it by its name only.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Yes, This Is the Game") {
                    contributions.confirmIdentity(candidate, for: game)
                    identity = candidate
                }
            }
        case .unknown:
            Text("Cartouche can’t tell which store game this is, so it can’t be shared yet.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PreviewSection: View {
    let body_: Data?
    let note: String

    var body: some View {
        Section("What will be shared") {
            ScrollView {
                Text(verbatim: body_.flatMap { pretty($0) } ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pretty(_ data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}

struct ShareResultsSheet: View {
    let game: Game
    @Bindable var model: LibraryModel
    let compat: CompatibilityModel
    let contributions: ContributionsModel
    let method: PlayMethod

    @Environment(\.dismiss) private var dismiss
    @Environment(PerformanceModel.self) private var performance: PerformanceModel?
    @State private var identity: ContributionGame?
    @State private var sessions: [StoredSession] = []
    @State private var sessionID: Int64?
    @State private var draft: ReportDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share My Results").font(.system(size: 17, weight: .bold)).padding([.horizontal, .top], 20)
            Form {
                Section { IdentityRow(game: game, contributions: contributions, identity: $identity) }
                if draft != nil { fields }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Draft") { save(confirm: false) }.disabled(draft == nil)
                Button("Share") { save(confirm: true) }.keyboardShortcut(.defaultAction).disabled(draft == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 580, height: 680)
        .task(id: identity) { await prepare() }
    }

    @ViewBuilder
    private var fields: some View {
        let binding = Binding(get: { draft! }, set: { draft = $0 })
        Section {
            if !sessions.isEmpty {
                Picker("Session", selection: Binding(get: { sessionID }, set: { sessionID = $0; Task { await prepare(keepAnswers: true) } })) {
                    Text("No session").tag(Int64?.none)
                    ForEach(sessions.reversed().prefix(10)) { s in
                        Text(verbatim: s.ended.formatted(date: .abbreviated, time: .shortened)).tag(Int64?.some(s.id))
                    }
                }
            }
            Picker("Result", selection: binding.outcome) {
                ForEach(ContributionWire.Outcome.allCases) { Text($0.label).tag($0) }
            }
            Stepper(value: binding.crashes, in: 0...100) { LabeledContent("Crashes") { Text(verbatim: "\(binding.wrappedValue.crashes)") } }
            Picker("Controller", selection: binding.controller) {
                ForEach(ContributionWire.Controller.allCases) { Text($0.label).tag($0) }
            }
            TextField("Comment", text: binding.comment, axis: .vertical).lineLimit(2...5)
            Text("A playable result is your judgement: a frame rate or a clean exit alone doesn’t prove it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let anti = binding.wrappedValue.antiCheat {
            Section("Anti-cheat") {
                Picker("Mode tested", selection: Binding(get: { anti.mode }, set: { draft?.antiCheat?.mode = $0 })) {
                    ForEach(ContributionWire.AntiCheat.Mode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Result", selection: Binding(get: { anti.result }, set: { draft?.antiCheat?.result = $0 })) {
                    ForEach(ContributionWire.AntiCheat.Result.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        Section {
            Toggle("Share statistics and this Mac’s hardware", isOn: binding.shareStatistics)
            Text("Off: the report has no chip, memory, macOS version or FPS.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        PreviewSection(body_: contributions.reportBody(binding.wrappedValue),
                       note: String(localized: "Published under CC0 1.0 once a moderator approves it. No account, Steam ID, path or log is sent. You can edit or withdraw it from My Contributions."))
    }

    private func prepare(keepAnswers: Bool = false) async {
        guard let identity else { return }
        if sessions.isEmpty, let appID = game.steamAppID, let store = performance?.store {
            sessions = await Task.detached { (try? store.sessions(appID: appID)) ?? [] }.value
            if sessionID == nil { sessionID = sessions.last?.id }
        }
        let session = sessions.first { $0.id == sessionID }
        var excluded: Int?
        if let session, let store = performance?.store {
            excluded = await Task.detached { (try? store.samples(session: session.id)).map { $0.filter { !$0.counted }.count } }.value
        }
        var next = contributions.reportDraft(for: game, identity: identity, session: session, library: model,
                                             resolved: compat.resolved(game, method: method), excludedSeconds: excluded)
        if keepAnswers, let old = draft {
            next.outcome = old.outcome
            next.crashes = old.crashes
            next.controller = old.controller
            next.comment = old.comment
            next.shareStatistics = old.shareStatistics
            next.antiCheat = old.antiCheat ?? next.antiCheat
        }
        draft = next
    }

    private func save(confirm: Bool) {
        guard let draft, let body = contributions.reportBody(draft) else { return }
        contributions.add(.report, game: draft.game, summary: "\(draft.game.title) · \(draft.outcome.label)", body: body, confirm: confirm)
        dismiss()
    }
}

struct ShareFixSheet: View {
    let game: Game
    @Bindable var model: LibraryModel
    let contributions: ContributionsModel

    @Environment(\.dismiss) private var dismiss
    @State private var identity: ContributionGame?
    @State private var draft: FixDraft?
    @State private var include = Include()

    struct Include: Equatable {
        var backend = true
        var translation = true
        var version = true
        var hud = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share a Fix").font(.system(size: 17, weight: .bold)).padding([.horizontal, .top], 20)
            Form {
                Section { IdentityRow(game: game, contributions: contributions, identity: $identity) }
                if let draft { fields(draft) }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Draft") { save(confirm: false) }.disabled(!ready)
                Button("Share") { save(confirm: true) }.keyboardShortcut(.defaultAction).disabled(!ready)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 580, height: 700)
        .onChange(of: identity) { _, id in
            if let id { draft = contributions.fixDraft(for: game, identity: id, library: model) }
        }
    }

    private var ready: Bool { selected.map(\.missing.isEmpty) ?? false }

    private var selected: FixDraft? {
        guard var d = draft else { return nil }
        if !include.backend { d.values.backend = nil }
        if !include.translation { d.values.translation = nil }
        if !include.version { d.values.version = nil }
        if !include.hud { d.values.metalHUD = nil }
        return d
    }

    @ViewBuilder
    private func fields(_ d: FixDraft) -> some View {
        let binding = Binding(get: { draft! }, set: { draft = $0 })
        Section {
            TextField("Title", text: binding.title)
            TextField("Problem it solves", text: binding.problem, axis: .vertical).lineLimit(2...4)
            TextField("When it worked (optional)", text: binding.conditions, axis: .vertical).lineLimit(1...3)
        }
        Section("Settings in this fix") {
            if let v = d.values.backend { Toggle("Graphics: \(GraphicsBackend(rawValue: v)?.label ?? v)", isOn: $include.backend) }
            if let v = d.values.translation { Toggle("Translation: \(GameSetupChoice.Translation(rawValue: v)?.label ?? v)", isOn: $include.translation) }
            if let v = d.values.version { Toggle("Run: \(GameVersion(rawValue: v)?.label ?? v)", isOn: $include.version) }
            if d.values.metalHUD == true { Toggle("Metal HUD on", isOn: $include.hud) }
            Text("Only these settings can be shared as a fix. Environment variables, launch arguments, file patches and commands can’t.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Game version") {
                Text(verbatim: d.gameBuild ?? String(localized: "Unknown"))
            }
            if d.gameBuild == nil {
                Text("Cartouche can’t read this game’s version. The fix will say so instead of naming one.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if ContributionLabel.clean(d.runnerBuild) == nil {
                Text("Choose a runner first: a fix names the runner it worked with.").font(.system(size: 11)).foregroundStyle(Color.orange)
            }
        }
        let reports = identity.map { contributions.reports(for: $0) } ?? []
        if !reports.isEmpty {
            Section("Supporting report") {
                ForEach(reports) { item in
                    Toggle(item.summary, isOn: Binding(
                        get: { draft?.validationReportIDs.contains(item.remoteID ?? "") ?? false },
                        set: { on in
                            guard let id = item.remoteID else { return }
                            if on { draft?.validationReportIDs.append(id) } else { draft?.validationReportIDs.removeAll { $0 == id } }
                        }))
                }
                Text("A pending report counts once a moderator publishes it.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        PreviewSection(body_: selected.flatMap { try? ContributionWire.encode($0.recipe()) },
                       note: String(localized: "Sent as a proposal under CC0 1.0. Nobody’s setup changes until a moderator publishes it and a player chooses to apply it."))
    }

    private func save(confirm: Bool) {
        guard let d = selected, d.missing.isEmpty, let body = try? ContributionWire.encode(d.recipe()) else { return }
        contributions.add(.fix, game: d.game, summary: "\(d.game.title) · \(d.title)", body: body, confirm: confirm)
        dismiss()
    }
}

struct MyContributionsSheet: View {
    let contributions: ContributionsModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Contributions").font(.system(size: 17, weight: .bold)).padding([.horizontal, .top], 20)
            Form {
                if contributions.items.isEmpty {
                    Text("Nothing shared from this Mac yet.").foregroundStyle(.secondary)
                }
                if contributions.credentialUnsaved {
                    Text("The Keychain couldn’t keep your contributor key. After Cartouche quits, what you shared can no longer be edited from this Mac.")
                        .foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(contributions.items.reversed()) { item in
                    row(item)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Refresh") { Task { await contributions.refreshOwn() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 560)
        .task { await contributions.refreshOwn() }
    }

    @ViewBuilder
    private func row(_ item: ContributionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: item.summary).font(.system(size: 13, weight: .medium))
            Text(status(item)).font(.system(size: 12)).foregroundStyle(.secondary)
            if let reason = item.reason, item.moderation == .rejected {
                Text("Reason: \(reason)").font(.system(size: 12)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                switch item.transport {
                case .draft:
                    Button("Share") { contributions.confirm(item.id) }
                    Button("Delete Draft", role: .destructive) { contributions.remove(item.id) }
                case .confirmed, .failed:
                    Button("Cancel Sending", role: .destructive) { contributions.remove(item.id) }
                    if item.transport == .failed { Button("Try Again") { contributions.confirm(item.id) } }
                case .received:
                    withdraw(item)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func withdraw(_ item: ContributionItem) -> some View {
        if let id = item.remoteID, item.moderation == .pending || item.moderation == .published {
            switch item.kind {
            case .report, .reportRevision:
                Button("Withdraw", role: .destructive) {
                    contributions.add(.reportWithdrawal, game: item.game, summary: String(localized: "Withdraw: \(item.summary)"),
                                      body: nil, confirm: true, remoteID: id, version: item.remoteVersion ?? 1)
                }
            case .fix, .fixRevision:
                Button("Withdraw", role: .destructive) {
                    contributions.add(.fixWithdrawal, game: item.game, summary: String(localized: "Withdraw: \(item.summary)"),
                                      body: nil, confirm: true, remoteID: id, revision: item.remoteRevision ?? 1)
                }
            default:
                EmptyView()
            }
        }
    }

    private func status(_ item: ContributionItem) -> String {
        switch item.transport {
        case .draft: return String(localized: "Draft, not sent")
        case .confirmed:
            return item.lastError == nil ? String(localized: "Waiting to be sent") : String(localized: "Waiting to be sent: the site can’t be reached")
        case .failed: return String(localized: "Not accepted by the site")
        case .received:
            switch item.moderation ?? .pending {
            case .pending: return String(localized: "Waiting for moderation")
            case .published: return String(localized: "Published")
            case .rejected: return String(localized: "Rejected")
            case .withdrawn: return String(localized: "Withdrawn")
            case .revoked: return String(localized: "Withdrawn from players")
            }
        }
    }
}

struct FixReviewSheet: View {
    let game: Game
    let ref: CommunityFeed.FixRef
    let feedGameID: String
    @Bindable var model: LibraryModel
    let contributions: ContributionsModel

    @Environment(\.dismiss) private var dismiss
    @State private var load: ContributionsModel.FixLoad?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shared Fix").font(.system(size: 17, weight: .bold)).padding([.horizontal, .top], 20)
            Form { content }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if case .ready(let fix, let plan) = load {
                    Button("Apply Fix") {
                        contributions.apply(plan, fix: fix, game: game, library: model)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canApply)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540, height: 560)
        .task { load = await contributions.loadFix(ref, game: game, feedGameID: feedGameID, library: model) }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case nil:
            ProgressView()
        case .unavailable:
            Text("The fix couldn’t be downloaded. Try again when you’re online.").foregroundStyle(.secondary)
        case .refused(let refusal):
            Text(ContributionsModel.refusal(refusal)).foregroundStyle(Color.orange)
        case .ready(let fix, let plan):
            Section {
                Text(verbatim: fix.recipe.title).font(.system(size: 13, weight: .semibold))
                // Contribution text is shown as plain text, never run
                Text(verbatim: fix.recipe.description).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Tested with") {
                    Text(verbatim: (fix.recipe.appliesTo.runnerBuilds + fix.recipe.appliesTo.backends).joined(separator: ", "))
                }
                LabeledContent("Game version") {
                    Text(verbatim: fix.recipe.appliesTo.gameBuilds.isEmpty ? String(localized: "Not recorded") : fix.recipe.appliesTo.gameBuilds.joined(separator: ", "))
                }
            }
            Section("Changes") {
                if plan.changes.isEmpty { Text("Your setup already matches this fix.").foregroundStyle(.secondary) }
                ForEach(plan.changes) { change in
                    LabeledContent(change.setting) { Text(verbatim: "\(change.from) → \(change.to)") }
                }
                Text("Your current setup is saved first. Undo Fix in the game panel brings it back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.mismatches.isEmpty {
                Section("Doesn’t match this setup") {
                    ForEach(plan.mismatches, id: \.self) { Text(Self.mismatch($0)) }
                }
            }
        }
    }

    static func mismatch(_ m: FixPlan.Mismatch) -> String {
        switch m {
        case .runner: String(localized: "It was tested with another runner.")
        case .backend: String(localized: "It was tested with another graphics backend.")
        case .gameBuild: String(localized: "It was tested with another version of the game.")
        case .unknownGameBuild: String(localized: "Cartouche can’t read this game’s version to compare it.")
        case .backendNotOffered: String(localized: "Its graphics backend isn’t available on this Mac.")
        case .macVersion: String(localized: "This game has no Mac version.")
        }
    }
}
