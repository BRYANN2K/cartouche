import SwiftUI

struct PrefixesView: View {

    @Environment(PrefixesModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sortOrder = [KeyPathComparator(\PrefixRow.lastUsed, order: .reverse)]
    @State private var winetricksPrefix: WinePrefix?
    @State private var winetricksVerbs = ""

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Looking for prefixes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.prefixes.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Prefixes"),
                    systemImage: "externaldrive",
                    description: Text(
                        String(localized: "Each Windows game Cartouche installs, imports or plays from Steam or a store keeps its own prefix. They show here once a game has one.")
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let failed = model.report {
                report(
                    StatusRow(
                        title: String(localized: "Failed"),
                        value: failed.message,
                        tone: .bad,
                        action: failed.settingsPane.map { pane in
                            StatusAction(label: Remedy.settingsButton) { Remedy.openSettings(pane) }
                        }
                    )
                )
            } else if let outcome = model.outcome {
                report(
                    StatusRow(
                        title: String(localized: "Done"),
                        value: outcome,
                        tone: .ok
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                strip
                Spacer()
                Menu("Actions") { actions(for: model.selection) }
                    .disabled(model.selection.isEmpty || model.isBusy)
            }
            .controlSize(.small)
            .padding(12)
            .background(.bar)
        }
        .task { await model.load() }
        .confirmationDialog(
            PrefixPrompt.deleteTitle(deleting),
            isPresented: asking(.delete),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.deleteButton(deleting), role: .destructive) {
                let targets = deleting
                model.pendingConfirmation = nil
                Task { await model.delete(targets) }
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(PrefixPrompt.deleteMessage(deleting))
        }
        .confirmationDialog(
            PrefixPrompt.rebuildTitle(rebuilding, for: rebuildTool),
            isPresented: asking(.rebuild),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.rebuildWithBackupButton(rebuilding)) {
                model.confirmRebuild()
            }
            .keyboardShortcut(.defaultAction)
            Button(PrefixPrompt.rebuildWithoutBackupButton(rebuilding)) {
                model.confirmRebuild(keepBackup: false)
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.rebuildMessage())
        }
        .confirmationDialog(
            PrefixPrompt.backUpTitle(backingUp),
            isPresented: asking(.backUp),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.backUpButton(backingUp)) {
                let targets = backingUp
                model.pendingConfirmation = nil
                Task { await model.backUp(targets) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.backUpMessage(backingUp))
        }
        .alert(
            "Winetricks",
            isPresented: Binding(
                get: { winetricksPrefix != nil },
                set: { if !$0 { winetricksPrefix = nil } }
            ),
            presenting: winetricksPrefix
        ) { prefix in
            TextField("vcrun2022 corefonts", text: $winetricksVerbs)
            Button("Install") {
                let verbs = winetricksVerbs
                Task { await model.winetricks(verbs, in: prefix) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(PrefixTools.winetricksVerbs(winetricksVerbs).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { prefix in
            Text("Enter the Winetricks verbs to install in \(prefix.title), separated by spaces.")
        }
    }

    private enum Question {
        case delete, rebuild, backUp
    }

    private var deleting: [WinePrefix] {
        if case .delete(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuilding: [WinePrefix] {
        if case .rebuild(let targets, _) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuildTool: InstalledTool? {
        if case .rebuild(_, let tool) = model.pendingConfirmation { return tool }
        return nil
    }

    private var backingUp: [WinePrefix] {
        if case .backUp(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private func isAsking(_ question: Question) -> Bool {
        switch (question, model.pendingConfirmation) {
        case (.delete, .delete): true
        case (.rebuild, .rebuild(_, _)): true
        case (.backUp, .backUp): true
        default: false
        }
    }

    private func asking(_ question: Question) -> Binding<Bool> {
        Binding(
            get: { isAsking(question) },
            set: { shown in
                if !shown, isAsking(question) { model.pendingConfirmation = nil }
            }
        )
    }

    @ViewBuilder
    private var strip: some View {
        Menu {
            toolButtons(for: model.selectedPrefix)
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(model.selectedPrefix?.canRunTools != true || model.isBusy)
        .help("Run a program or open a Wine tool in the selected prefix.")

        Button("Reveal in Finder", systemImage: "folder") {
            if let prefix = model.selectedPrefix { model.reveal(prefix) }
        }
        .disabled(model.selectedPrefix == nil)
        .help("Show the selected prefix in the Finder.")

        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("List the prefixes again and update their sizes.")
    }

    private func lastUsed(_ prefix: WinePrefix) -> String {
        prefix.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Never")
    }

    private var sourceWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(\.source.label)) ?? 120
    }

    private var toolWidth: CGFloat {
        TextWidth.widest(model.prefixes.compactMap(model.lastTool)) ?? 60
    }

    private var lastUsedWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(lastUsed)) ?? 110
    }

    private var gameWidth: CGFloat {
        let widths = model.prefixes.map { prefix -> CGFloat in
            var width = min(TextWidth.of(prefix.title), TextWidth.maxTitle)
            if model.isStale(prefix) { width += 22 }
            if prefix.name == nil {
                width += TextWidth.of(String(localized: "No longer installed"), size: NSFont.smallSystemFontSize) + 6
            }
            return width
        }
        guard let widest = widths.max() else { return 240 }
        return widest + TextWidth.cellPadding
    }

    private struct PrefixRow: Identifiable {
        let prefix: WinePrefix
        let tool: String
        let source: String
        let size: Int64
        let title: String
        let lastUsed: Date

        var id: WinePrefix.ID { prefix.id }
    }

    private var rows: [PrefixRow] {
        model.prefixes.map { prefix in
            PrefixRow(
                prefix: prefix,
                tool: model.lastTool(prefix) ?? "",
                source: prefix.source.label,
                size: model.usage[prefix.id]?.bytes ?? -1,
                title: prefix.title,
                lastUsed: prefix.lastUsed ?? .distantPast
            )
        }
        .sorted(using: sortOrder)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Game", value: \.title) { row in
                let prefix = row.prefix
                HStack(spacing: 6) {
                    if model.isStale(prefix) {
                        Menu {
                            rebuildChoices([prefix])
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isBusy || model.tools.isEmpty)
                        .accessibilityLabel("Needs rebuilding")
                    }
                    Text(prefix.title).lineLimit(1).help(prefix.title)
                    if prefix.name == nil {
                        Text("No longer installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if model.busy.contains(prefix.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .width(min: 60, ideal: gameWidth)

            TableColumn("Source", value: \.source) { row in
                Text(row.source)
                    .foregroundStyle(.secondary)
                    .help(origin(row.prefix))
            }
            .width(min: 44, ideal: sourceWidth)

            TableColumn("Runner", value: \.tool) { row in
                runnerCell(row.prefix)
            }
            .width(min: 60, ideal: toolWidth)

            TableColumn("Private Size", value: \.size) { row in
                if let usage = model.usage[row.id] {
                    Text(usage.bytes.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Calculating…")
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                }
            }
            .width(min: 56, ideal: 90)

            TableColumn("Last used", value: \.lastUsed) { row in
                Text(lastUsed(row.prefix))
                    .foregroundStyle(.secondary)
                    .help(lastUsed(row.prefix))
            }
            .width(min: 60, ideal: lastUsedWidth)

        }
        .contextMenu(forSelectionType: WinePrefix.ID.self) { ids in
            actions(for: ids)
        }
        .onDeleteCommand {
            let targets = model.selectedPrefixes
            if !model.isBusy, !targets.isEmpty {
                model.pendingConfirmation = .delete(targets)
            }
        }
    }

    @ViewBuilder
    private func actions(for ids: Set<WinePrefix.ID>) -> some View {
        let targets = model.prefixes.filter { ids.contains($0.id) }
        Group {
            if let prefix = single(ids) {
                if prefix.canRunTools {
                    toolButtons(for: prefix)
                    Divider()
                }
                Button("Reveal in Finder") { model.reveal(prefix) }
                Menu("Open Log") {
                    ForEach(PrefixLog.allCases, id: \.self) { log in
                        Button(log.label) { model.open(log, for: prefix) }
                            .disabled(!model.hasLog(log, for: prefix))
                    }
                }
            }
            if !targets.isEmpty {
                Divider()
                Button(PrefixPrompt.backUpButton(targets)) {
                    model.pendingConfirmation = .backUp(targets)
                }
                if targets.allSatisfy(\.canRebuild) {
                    rebuildMenu(targets)
                }
                if targets.allSatisfy(\.canDelete) {
                    Button(PrefixPrompt.deleteButton(targets), role: .destructive) {
                        model.pendingConfirmation = .delete(targets)
                    }
                }
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func rebuildMenu(_ targets: [WinePrefix]) -> some View {
        if model.tools.count > 1 {
            Menu(PrefixPrompt.rebuildButton(targets)) { rebuildChoices(targets) }
        } else {
            rebuildChoices(targets, label: PrefixPrompt.rebuildButton(targets))
        }
    }

    @ViewBuilder
    private func runnerCell(_ prefix: WinePrefix) -> some View {
        if let tool = model.lastTool(prefix) {
            Text(tool).foregroundStyle(.secondary).help(tool)
        } else if case .store = prefix.source {
            Text("Game’s setup").foregroundStyle(.secondary)
        } else {
            Text("None")
                .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
        }
    }

    // Where the prefix sits: a Steam game's library and app ID, or the folder of a game Cartouche made.
    private func origin(_ prefix: WinePrefix) -> String {
        guard prefix.source == .steam else { return prefix.root.path(percentEncoded: false) }
        return "\(prefix.library.displayName) · \(prefix.appID)"
    }

    @ViewBuilder
    private func rebuildChoices(_ targets: [WinePrefix], label: String? = nil) -> some View {
        ForEach(model.tools) { tool in
            Button(label ?? tool.display) {
                model.pendingConfirmation = .rebuild(targets, tool)
            }
        }
    }

    @ViewBuilder
    private func toolButtons(for prefix: WinePrefix?) -> some View {
        Button("Run Program…") {
            if let prefix { model.chooseExecutable(for: prefix) }
        }
        Button("Winetricks…") {
            winetricksPrefix = prefix
        }
        Divider()
        ForEach(WineTool.allCases, id: \.self) { tool in
            Button(tool.label) {
                if let prefix { model.open(tool, for: prefix) }
            }
        }
    }

    private func single(_ ids: Set<WinePrefix.ID>) -> WinePrefix? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.prefixes.first { $0.id == id }
    }

    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
