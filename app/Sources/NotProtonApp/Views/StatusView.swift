import SwiftUI
import CartoucheIdentity

enum StatusTone: Sendable {
    case ok, info, warning, bad, neutral

    var symbol: String {
        switch self {
        case .ok: "circle.fill"
        case .info: "circle"
        case .warning: "circle.fill"
        case .bad: "circle.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

struct StatusAction {
    let label: String
    var isProminent = false
    var role: ButtonRole?
    var help: String?
    var isEnabled = true
    var startsGroup = false
    let perform: () -> Void
}

enum StatusMetrics {
    static let symbolWidth: CGFloat = 10
    static let symbolSpacing: CGFloat = 8
    static var textInset: CGFloat { symbolWidth + symbolSpacing }
}

struct StatusRow: View {

    let title: String
    var value: String?

    var tone: StatusTone?
    var detail: String?
    var trailing: String?
    var secondaryAction: StatusAction?
    var action: StatusAction?
    var menu: [StatusAction] = []
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: StatusMetrics.symbolSpacing) {
                if let tone {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(tone.color)
                        .frame(width: StatusMetrics.symbolWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: StatusMetrics.symbolWidth, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let value {
                        Text(value)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if secondaryAction != nil || action != nil || !menu.isEmpty || toggle != nil || trailing != nil {
                Spacer(minLength: 12)
            }
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, action == nil && menu.isEmpty ? 0 : 8)
            }
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let secondaryAction {
                button(secondaryAction)
                    .disabled(!secondaryAction.isEnabled)
                    .help(secondaryAction.help ?? "")
                    .accessibilityLabel("\(secondaryAction.label), \(title)")
                    .padding(.trailing, 8)
            }
            if let action {
                button(action)
                    .disabled(!action.isEnabled)
                    .help(action.help ?? "")
                    .accessibilityLabel("\(action.label), \(title)")
            }
            if !menu.isEmpty {
                Menu {
                    menuItems(menu, hidingUnavailable: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions, \(title)")
                .padding(.leading, action == nil ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            menuItems([action, secondaryAction].compactMap { $0 } + menu, hidingUnavailable: true)
        }
    }

    @ViewBuilder
    private func menuItems(_ items: [StatusAction], hidingUnavailable: Bool) -> some View {
        let shown = hidingUnavailable ? items.filter(\.isEnabled) : items
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            Button(item.label, role: item.role, action: item.perform)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func button(_ action: StatusAction) -> some View {
        if action.isProminent {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.bordered)
        }
    }
}

struct StatusView: View {
    @Environment(SystemStatus.self) private var status
    @Environment(RunnersModel.self) private var runners: RunnersModel?

    private static let updateBlockPrompt =
        String(localized: "Steam client updates may break Cartouche. If you don't want to wait for Cartouche to be updated to be compatible with future Steam versions at the cost of not getting updates to the Steam client, you can stop the Steam client from updating itself.")

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            String(localized: "Block Steam client updates?"),
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            String(localized: "Replace Steam with Valve's bundle?"),
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button("Replace Steam", role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(localized: "This will restore Steam itself to its original state but does not remove the support components used by Cartouche.")
            )
        }
        .confirmationDialog(
            String(localized: "Remove everything Cartouche has created?"),
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Uninstall.confirmation())
        }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.installUnlicensed),
            titleVisibility: .visible
        ) {
            Button("Continue Anyway") {
                Task { await status.installIntoSteam(repairing: status.pendingRepair) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                CrossOverLicense.notActivatedAdvice
                    + String(localized: " Cartouche can be deployed, but the CrossOver compatibility tool cannot be installed without a valid license.")
            )
        }
        .confirmationDialog(
            String(localized: "Quit Steam?"),
            isPresented: asking(.quitSteam),
            titleVisibility: .visible
        ) {
            Button(status.pendingSteamAction.flatMap { SteamIntegrationLine.label(for: $0, quitsSteam: true) }
                   ?? String(localized: "Quit Steam")) {
                Task { await status.confirmQuitSteam() }
            }
            Button("Cancel", role: .cancel) { status.cancelQuitSteam() }
        } message: {
            Text("Steam closes while Cartouche updates its files. Open Steam again when Cartouche is done.")
        }
        .task { if status.snapshot == nil { await status.refresh() } }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.toolUnlicensed),
            titleVisibility: .visible
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(CrossOverLicense.notActivatedAdvice)
        }
    }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func statusForm(_ snapshot: StatusSnapshot) -> some View {
        form(snapshot)
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            if let failure = status.failure {
                StatusRow(
                    title: String(localized: "Failed"),
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    }
                )
            } else if let outcome = status.outcome {
                StatusRow(
                    title: String(localized: "Done"), value: outcome, tone: .ok,
                    action: status.steamStoppedByRun ? openSteamAction : nil
                )
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: String(localized: "Template cleanup incomplete"), value: failure, tone: .warning)
            }

            if let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
            }

            SteamIntegrationBanner(inSettings: true)

            Section {
                integrationRow(snapshot)
            }

            Section {
                StatusRow(
                    title: String(localized: "Location"),
                    value: SupportPaths.Steam.app.path(percentEncoded: false),
                    action: StatusAction(
                        label: String(localized: "Choose\u{2026}"),
                        help: String(localized: "Use a copy of Steam from another folder or drive."),
                        isEnabled: status.isIdle
                    ) { Task { await status.chooseSteam() } }
                )
                updateBlockRow(snapshot.updateBlocked)
                StatusRow(
                    title: String(localized: "Controller permission"),
                    value: String(localized: "Clear Steam's controller permission so macOS asks for it again."),
                    action: StatusAction(
                        label: String(localized: "Reset"),
                        isEnabled: status.isIdle
                    ) { Task { await status.resetControllerPermission() } }
                )
                // Blocked content makes every install action refuse, and the Cartouche line says why
                if !snapshot.installContent.blocksInstallation {
                    StatusRow(
                        title: String(localized: "Valve binaries"),
                        value: String(localized: "Download Valve’s Steam Play files again if some are missing."),
                        action: StatusAction(
                            label: String(localized: "Fetch Valve Binaries"),
                            isEnabled: status.canInstall
                        ) { Task { await status.fetchValveBinaries() } }
                    )
                }
            }

            componentsSection(snapshot.payload)

            Section("Compatibility Tool") {
                if let runners, !hasWineTool(runners), let build = wineToolBuild(runners) {
                    StatusRow(
                        title: RunnerManifest.Build.cartoucheName,
                        value: String(localized: "None installed. Steam needs one to run Windows games."),
                        action: StatusAction(
                            label: String(localized: "Install Cartouche Wine"),
                            isProminent: true,
                            isEnabled: status.isIdle && !runners.busy.contains(build.id)
                        ) { Task { await runners.perform(.download, on: build.id); await status.refresh() } })
                }
                StatusRow(title: String(localized: "Compatibility Tool"),
                          action: StatusAction(label: String(localized: "Set Up Compatibility Tool"),
                                               isEnabled: status.isIdle && status.canSetUpTool) {
                    Task { await status.requestCompatibilityTool() }
                })
            }

            dangerSection
        }
        .formStyle(.grouped)
    }

    private func hasWineTool(_ runners: RunnersModel) -> Bool {
        runners.registry.runners.contains {
            $0.isOffered || ($0.kind == .wineBuild && $0.isInstalled
                            && runners.manifest.build(id: $0.id)?.origin == .cartouche)
        }
    }

    private func wineToolBuild(_ runners: RunnersModel) -> RunnerManifest.Build? {
        runners.manifest.builds.first {
            $0.kind == Runner.Kind.wineBuild.rawValue && $0.origin == .cartouche && $0.isPinned
        }
    }

    private var dangerSection: some View {
        Section {
            StatusRow(
                title: String(localized: "Repair Steam"),
                value: String(localized: "Restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Repair"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: String(localized: "Remove Everything"),
                value: String(localized: "Remove Cartouche and restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Remove"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var openSteamAction: StatusAction {
        StatusAction(label: String(localized: "Open Steam")) { Task { await status.openSteam() } }
    }

    private func integrationRow(_ snapshot: StatusSnapshot) -> some View {
        let line = SteamIntegrationLine.make(snapshot, canInstall: status.canInstall, upkeep: status.upkeep)
        return StatusRow(
            title: String(localized: "Steam Integration"),
            value: line.value,
            tone: line.tone,
            detail: line.detail,
            action: line.action.map { action in
                StatusAction(label: line.label ?? "", isProminent: true, help: line.help, isEnabled: line.isEnabled) {
                    Task { await status.request(action, quittingSteam: line.quitsSteam) }
                }
            }
        )
        .help(line.files.joined(separator: "\n"))
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: String(localized: "Block Steam client updates"),
            value: blocked
                ? String(localized: "The Steam client will not update itself.")
                : String(localized: "A Steam client update may break Cartouche."),
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help("Steam client updates may break Cartouche.")
    }

    private var blockUpdates: Binding<Bool> {
        Binding(
            get: { status.snapshot?.updateBlocked ?? false },
            set: { wanted in
                if wanted {
                    status.pendingConfirmation = .blockUpdates
                } else {
                    Task { await status.setUpdateBlock(false) }
                }
            }
        )
    }

    nonisolated static func sizeText(runner: Int64, templates: [CompatTool.Flavor: Int64], flavors: [CompatTool.Flavor]) -> String {
        let lines: [String]
        if flavors.count > 1 {
            lines = flavors.compactMap { flavor in
                guard let bytes = templates[flavor], bytes > 0 else { return nil }
                return String(localized: "\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))")
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? [String(localized: "Templates \(bytes.formatted(.byteCount(style: .file)))")] : []
        }
        return ([String(localized: "Runner \(runner.formatted(.byteCount(style: .file)))")] + lines).joined(separator: "\n")
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: String(localized: "Fetch Valve Binaries"),
            isProminent: true,
            help: String(localized: "Download missing Valve binaries."),
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        if let problem = payload.manifestProblem {
            Section("Cartouche Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Component list unreadable."), tone: .bad, detail: problem)
            }
        } else if payload.isComplete {
            Section("Cartouche Components") {
                StatusRow(
                    title: String(localized: "Components"), value: String(localized: "Ready."), tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? String(localized: "Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))") : nil
                )
            }
        } else if payload.isEmpty {
            Section("Cartouche Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Not yet deployed."), tone: .neutral)
            }
        } else {
            Section("Cartouche Components") {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map(\.path).joined(separator: ", ")
                    StatusRow(
                        title: String(localized: "Missing."),
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: String(localized: "Overlay shim"), value: String(localized: "Missing."), tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: String(localized: "Signature database"), value: String(localized: "Missing."), tone: .bad)
                }
            }
        }
    }
}

// The one Cartouche line in Settings > Steam: a plain status and at most one action.
struct SteamIntegrationLine: Equatable {
    enum Action: Equatable, Sendable {
        case install, update, repair, replaceNotProton
    }

    var value: String
    var tone: StatusTone
    var detail: String?
    var files: [String] = []
    var action: Action?
    var quitsSteam = false
    var isEnabled = false

    var label: String? { action.flatMap { Self.label(for: $0, quitsSteam: quitsSteam) } }

    var help: String? {
        switch action {
        case .replaceNotProton: String(localized: "Remove NotProton from Steam and install Cartouche.")
        case .install, .update, .repair: String(localized: "Install Cartouche into Steam.")
        case nil: nil
        }
    }

    static func label(for action: Action, quitsSteam: Bool) -> String? {
        switch (action, quitsSteam) {
        case (.install, false): String(localized: "Install")
        case (.install, true): String(localized: "Quit Steam and Install")
        case (.update, false): String(localized: "Update")
        case (.update, true): String(localized: "Quit Steam and Update")
        case (.repair, false): String(localized: "Repair")
        case (.repair, true): String(localized: "Quit Steam and Repair")
        case (.replaceNotProton, _): String(localized: "Replace NotProton")
        }
    }

    static func make(_ snapshot: StatusSnapshot, canInstall: Bool, upkeep: SteamUpkeep.State = .idle) -> Self {
        var line = base(snapshot)
        if let action = line.action {
            line.isEnabled = canInstall
            line.quitsSteam = snapshot.steamRunning && action != .replaceNotProton
        }
        let installed = snapshot.steamIntegrationVersion ?? String(localized: "Legacy")
        let versions = installed == CARTOUCHE_STEAM_INTEGRATION_VERSION
            ? String(localized: "Version \(installed)")
            : "\(installed) → \(CARTOUCHE_STEAM_INTEGRATION_VERSION)"
        if line.action == .update {
            line.detail = versions
        } else if line.action == .repair {
            line.detail = [line.detail, versions].compactMap { $0 }.joined(separator: "\n")
        }
        if line.action == nil { line.quitsSteam = false }
        return line
    }

    private static func base(_ snapshot: StatusSnapshot) -> Self {
        switch snapshot.steam {
        case .steamMissing:
            return Self(value: String(localized: "Steam not found."), tone: .bad)
        case .foreign:
            return Self(value: String(localized: "Another dylib is present."), tone: .warning,
                        detail: String(localized: "Repair your Steam install before installing Cartouche."))
        case .notProton:
            return Self(value: String(localized: "Steam uses NotProton."), tone: .warning,
                        detail: String(localized: "Cartouche replaces NotProton inside Steam. NotProton's app and data stay on this Mac. To switch back, remove Cartouche and install NotProton again."),
                        action: .replaceNotProton)
        case .notInstalled:
            guard snapshot.installContent.blocksInstallation else {
                return Self(value: String(localized: "Not installed."), tone: .neutral, action: .install)
            }
            return content(snapshot, version: nil)
        case .installed(let version):
            return content(snapshot, version: snapshot.steamIntegrationVersion ?? version)
        case .outdated(let deployed, let bundled):
            guard snapshot.installContent != .unchecked else {
                return Self(value: String(localized: "Update available (\(bundled))."), tone: .warning, action: .update)
            }
            return content(snapshot, version: deployed)
        }
    }

    private static func content(_ snapshot: StatusSnapshot, version: String?) -> Self {
        switch snapshot.installContent {
        case .unchecked, .current:
            let payload = snapshot.payload
            guard payload.isSteamComplete else {
                return Self(value: String(localized: "Steam integration needs repair."), tone: .warning,
                            detail: missingDetail(payload), action: .repair)
            }
            return Self(value: String(localized: "Installed") + (version.map { " (\($0))" } ?? ""), tone: .ok)
        case .newerInstalled:
            return Self(value: String(localized: "A newer build is installed."), tone: .neutral,
                        detail: String(localized: "Use the newer Cartouche app to update or repair the installed files."))
        case .unavailable(let reason):
            return Self(value: String(localized: "Could not check installed files."), tone: .warning, detail: reason)
        case .update(let files):
            return Self(value: String(localized: "Update available."), tone: .warning,
                        detail: String(localized: "This app includes newer files than those installed for Steam."),
                        files: files, action: .update)
        case .repair(let files):
            return Self(value: String(localized: "Cartouche in Steam needs a repair."), tone: .warning,
                        detail: String(localized: "Restore the files included with this app."),
                        files: files, action: .repair)
        case .mismatchedDylib(let files):
            return Self(value: String(localized: "Cartouche in Steam needs a repair."), tone: .warning,
                        detail: String(localized: "Steam has a Cartouche build that this app did not install. Repair installs this app’s build."),
                        files: files, action: .repair)
        case .unrecorded(let files):
            return Self(value: String(localized: "Update available."), tone: .warning,
                        detail: String(localized: "This app includes updated files for Steam."),
                        files: files, action: .update)
        }
    }

    private static func missingDetail(_ payload: PayloadState) -> String {
        if let problem = payload.manifestProblem { return problem }
        var names = payload.missingSteamFiles
        if payload.signatureDatabase == nil { names.append(String(localized: "Signature database")) }
        return String(localized: "Missing: \(names.joined(separator: ", ")). Install to restore these files for your macOS user.")
    }
}
