
import AppKit
import RetroArchKit
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Label("Cartouche", systemImage: "rectangle.stack.fill")
                    .font(.system(size: 17, weight: .bold))
                    .padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OnboardingStep.allCases, id: \.self) { item in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(item == model.step ? Color.accentColor : Glass.fill2)
                                if item < model.step {
                                    Image(systemName: "checkmark")
                                } else {
                                    Text(verbatim: "\(item.index + 1)")
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(item == model.step ? Color.white : Glass.label2)
                            .frame(width: 24, height: 24)
                            Text(item.title).font(.system(size: 12, weight: item == model.step ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(item == model.step ? .primary : .secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(item == model.step ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityAddTraits(item == model.step ? .isSelected : [])
                    }
                }
                Spacer(minLength: 0)
                Label("Saved on this Mac", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 14).padding(.vertical, 30)
            .frame(width: 224)
            .background(Glass.fill)
            Divider().overlay(Glass.separator)
            VStack(spacing: 0) {
                HStack {
                    Text("Step \(model.step.index + 1) of \(OnboardingStep.allCases.count), \(model.step.title)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 32).padding(.top, 22)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.resumed {
                            ResumeBanner(step: model.step) { model.startOver() }
                        }
                        step
                            .transition(Motion(reduceMotion: reduceMotion).entrance)
                            .id(model.step)
                    }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .softScrollEdges()
                SetupTaskStrip(model: model)
                    .padding(.horizontal, 24)
                OnboardingFooter(model: model)
                    .padding(.horizontal, 24).padding(.vertical, 20)
            }
        }
        .frame(width: 900, height: 660)
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        .task { await model.prepare() }
        .animation(Motion(reduceMotion: reduceMotion).panel, value: model.step)
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .windowsGames: WindowsGamesStep(model: model)
        case .stores: StoresStep(model: model)
        case .consoles: ConsolesStep(model: model)
        case .controller: ControllerStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .ready: ReadyStep(model: model)
        }
    }
}

private struct SetupTaskStrip: View {
    let model: OnboardingModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.setup.anythingWorking ? "arrow.down.circle" : "checkmark.circle")
                .font(.system(size: 24)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                if let task = model.setup.activity {
                    Text(verbatim: task.title).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: task.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let fraction = task.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("Continues in Activity").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if let failed = model.readyTasks.first(where: { $0.state == .failed }) {
                    Text(verbatim: failed.title).font(.system(size: 11, weight: .semibold))
                    Text(verbatim: failed.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    if model.readyTasks.contains(where: { $0.state == .done && $0.id != "steam-library" }) {
                        Text("Ready").font(.system(size: 11, weight: .semibold))
                    } else {
                        Text("No background tasks").font(.system(size: 11, weight: .semibold))
                    }
                    Text("Downloads appear here and in Activity").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.readyTasks.contains(where: { $0.state == .failed }) {
                Button("Retry") { model.retrySetup() }.buttonStyle(.pill)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .groupBackground()
        .accessibilityElement(children: .contain)
    }
}

struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentColor : Glass.fill2)
                    .frame(width: step == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current.index + 1) of \(OnboardingStep.allCases.count), \(current.title)"))
    }
}

struct ResumeBanner: View {
    let step: OnboardingStep
    let startOver: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back").font(.system(size: 13, weight: .semibold))
                Text("You were setting up \(step.title). Your choices are kept.")
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Start Over", action: startOver).buttonStyle(.pill)
        }
        .padding(12)
        .groupBackground(tint: .accentColor)
    }
}

struct OnboardingFooter: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        HStack(spacing: 8) {
            if model.step != .welcome {
                Button("Back") { model.back() }.disabled(!model.canContinue)
            }
            Spacer()
            if model.step == .welcome {
                Button("Skip Setup") { model.skipAll() }
            } else if model.step.skippable {
                Button("Skip") { model.skip() }.disabled(!model.canContinue)
            }
            primary.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
        }
        .buttonStyle(.sheet)
    }

    @ViewBuilder
    private var primary: some View {
        switch model.step {
        case .welcome:
            Button("Continue") { model.next() }
        case .ready:
            Button("Open Library") { model.finish() }
        default:
            Button("Continue") { model.next() }
                .disabled(!model.canContinue)
        }
    }
}

private struct StepHeader: View {
    let title: Text
    let message: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.font( .system(size: 25, weight: .bold)).tracking(-0.6)
            message.font(.system(size: 13)).foregroundStyle(Glass.label2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct FoundRow<Trailing: View>: View {
    let title: Text
    var detail: Text?
    var monospaced = false
    var mark: PlatformMark?
    var stacked = false
    @ViewBuilder var trailing: Trailing

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(monospaced ? .system(size: 12, weight: .medium).monospaced() : .system(size: 13, weight: .medium))
            if let detail {
                detail.font(.system(size: 12)).foregroundStyle(Glass.label2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    label
                    trailing.frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    if let mark { PlatformMarkView(mark: mark).foregroundStyle(Color.accentColor) }
                    label
                    Spacer(minLength: 12)
                    trailing
                }
            }
        }
        .frame(minHeight: 38)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct Found: View {
    let label: Text

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
            label.foregroundStyle(Glass.label2)
        }
    }
}

private struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(Glass.separator).padding(.leading, 12) }
                    row
                }
            }
        }
        .groupBackground()
    }
}

// MARK: Welcome

private struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            StepHeader(title: Text("Make room for play."), message: Text("Here is what’s already on this Mac."))
            if let mac = model.machine {
                Label {
                    Text(verbatim: "\(mac.chip) · \(mac.memoryGB) GB · macOS \(mac.macOS)")
                } icon: {
                    Image(systemName: "laptopcomputer")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let found = model.findings {
                if found.isEmpty {
                    Text("Nothing to bring in yet. The next steps set up Windows games and consoles.")
                        .foregroundStyle(.secondary)
                } else {
                    FoundList(found: found)
                    let otherGames = model.library.allGames.filter { $0.installed && $0.source != .steam && !$0.source.isConsole }.count
                    if otherGames > 0 {
                        Text("\(otherGames) other installed games").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at this Mac…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FoundList: View {
    let found: MacFindings

    var body: some View {
        RowGroup {
            if let steam = found.steam {
                FoundRow(title: Text(verbatim: "Steam"), detail: Text(Self.steamLine(steam)), mark: .steam) {
                    Found(label: Text("Found"))
                }
            }
            ForEach(found.crossOver, id: \.name) { runner in
                FoundRow(title: Text(verbatim: runner.name), detail: Text("Runs Windows games with your copy of CrossOver")) {
                    Found(label: Text("Found"))
                }
            }
            ForEach(found.portingToolkit, id: \.name) { runner in
                FoundRow(title: Text(verbatim: runner.name), detail: Text("Gives Windows games D3DMetal, Apple’s DirectX 12 layer")) {
                    Found(label: Text("Found"))
                }
            }
            ForEach(Array(found.controllers.enumerated()), id: \.offset) { _, controller in
                FoundRow(title: Text(verbatim: controller.name),
                         detail: controller.battery.map { Text("Battery \($0)%") }) {
                    Found(label: Text("Connected"))
                }
            }
            ForEach(found.folders) { folder in
                FoundRow(title: Text(verbatim: folder.shortPath()), detail: Text(Self.folderLine(folder)), monospaced: true) {
                    Found(label: Text("Found"))
                }
            }
        }
    }

    nonisolated static func steamLine(_ steam: FoundSteam) -> String {
        let games = steam.games == 1 ? String(localized: "1 game") : String(localized: "\(steam.games) games")
        guard let account = steam.account else { return String(localized: "Not signed in") }
        return String(localized: "Signed in as \(account), \(games)")
    }

    nonisolated static func folderLine(_ folder: FoundFolder) -> String {
        let list = ListFormatter()
        list.locale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
        let names = list.string(from: folder.consoleNames) ?? folder.consoleNames.joined(separator: ", ")
        return folder.games == 1
            ? String(localized: "1 console game, for \(names)")
            : String(localized: "\(folder.games) console games, for \(names)")
    }
}

// MARK: Windows games

private struct WindowsGamesStep: View {
    @Bindable var model: OnboardingModel
    @State private var dropHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("Your Windows games, on Mac."),
                       message: Text("Choose a runner. Downloads won’t hold you up."))
            RowGroup {
                if let build = model.runner {
                    FoundRow(title: Text(verbatim: build.title),
                             detail: Text("Recommended — unlocks D3DMetal and DXMT")) {
                        runnerState
                    }
                }
                FoundRow(title: Text("D3DMetal"), detail: Text(model.toolkitStatus)) {
                    toolkitState
                }
            }
            if !model.toolkitReady {
                VStack(alignment: .leading, spacing: 8) {
                    Text("D3DMetal needs Apple’s Game Porting Toolkit. Use your own disk image from Apple.")
                        .font(.system(size: 12))
                        .foregroundStyle(Glass.label2)
                        .fixedSize(horizontal: false, vertical: true)
                    dropZone
                }
            }
            if let problem = model.setup.toolkit.problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = model.runnerPhase {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("DXMT and DXVK come with the runner — nothing to pick.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
            Text("You can skip this and play console games only.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
        }
    }

    @ViewBuilder
    private var runnerState: some View {
        switch model.runnerPhase {
        case .installed:
            Found(label: Text("Installed"))
        case .downloading:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
        case .failed:
            Button("Try Again") { model.startRunnerIfNeeded(force: true) }.buttonStyle(.pill)
        case .notInstalled, .none:
            Toggle(isOn: $model.wantsRunner) { Text("Get it") }
                .toggleStyle(RunnerChoiceSwitch())
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var toolkitState: some View {
        if model.setup.toolkit.working {
            ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
        } else if model.toolkitReady {
            Found(label: Text("Ready"))
        } else {
            EmptyView()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "shippingbox").font(.system(size: 20)).foregroundStyle(Glass.label2)
            Text("Drop the Game Porting Toolkit .dmg here")
                .font(.system(size: 12, weight: .medium))
            HStack {
                Button("Choose a disk image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.diskImage]
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { model.importToolkitImage(url) }
                }.buttonStyle(.pill)
                Button("Get it from Apple") { model.openToolkitHelp() }.buttonStyle(.pill)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(dropHover ? Color.accentColor.opacity(0.14) : Glass.fill,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropHover ? Color.accentColor : Glass.separator,
                              style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
        }
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "dmg" else { return }
                    Task { @MainActor in model.importToolkitImage(url) }
                }
            }
            return true
        }
    }
}

private struct RunnerChoiceSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.green : Glass.fill2)
                Circle().fill(.white).frame(width: 18, height: 18).padding(3)
            }
            .frame(width: 38, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Cartouche Wine"))
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

// MARK: Stores

private struct StoresStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("Bring your library along."),
                       message: Text("Connect now, or come back in Settings."))
            RowGroup {
                if model.findings?.steam != nil {
                    SteamStepRow(step: model.steamStep)
                        .padding(.vertical, 6)
                        .padding(.leading, 12 - StatusMetrics.textInset)
                        .padding(.trailing, 12)
                    FoundRow(title: Text("Steam library"),
                             detail: Text(model.steamLibraryDetail)) {
                        if model.steamLibraryGames > 0 {
                            Found(label: Text("Imported"))
                        } else {
                            Text("Waiting for Steam").foregroundStyle(Glass.label2)
                        }
                    }
                    if model.steamRestarted == false {
                        FoundRow(title: Text("Steam could not be opened")) {
                            Button("Open Steam") { Task { await model.restartSteamNow() } }
                                .buttonStyle(.pill)
                        }
                    }
                } else {
                    FoundRow(title: Text(verbatim: "Steam"),
                             detail: Text("Steam is not on this Mac. The Steam page of the library installs it."),
                             mark: .steam) {
                        EmptyView()
                    }
                }
            }
            storeTiles
        }
    }

    private var storeTiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other stores").groupHeader()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.storeTiles, id: \.self) { store in
                    StoreTile(store: store, model: model)
                }
            }
        }
    }
}

private struct StoreTile: View {
    let store: GameSource
    let model: OnboardingModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: store.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                status.font(.system(size: 11)).foregroundStyle(Glass.label2)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Glass.fill, in: shape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch model.connection(store) {
        case .connected(let account), .expired(let account): Text(verbatim: account)
        case .waiting: Text("Signing in…")
        case .notConnected: Text("Optional")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.connection(store) {
        case .connected:
            Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
        case .waiting:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Signing in"))
        case .notConnected, .expired:
            Button("Sign In") { model.beginSignIn(store) }.buttonStyle(.pill)
        }
    }
}

// MARK: Consoles

private struct ConsolesStep: View {
    @Bindable var model: OnboardingModel

    static let makers: [(String, [String])] = [
        ("Nintendo", ["nes", "snes", "n64", "gb", "gbc", "gba", "nds"]),
        ("Sega", ["genesis", "mastersystem", "gamegear"]),
        ("Sony", ["ps1"]),
    ]

    static let coreNames: [String: String] = [
        "nestopia": "Nestopia", "snes9x": "Snes9x", "mupen64plus_next": "Mupen64Plus-Next", "sameboy": "SameBoy",
        "mgba": "mGBA", "melonds": "melonDS", "genesis_plus_gx": "Genesis Plus GX",
        "mednafen_pce_fast": "Beetle PCE Fast", "swanstation": "SwanStation", "stella": "Stella",
    ]

    static var groups: [(String, [Console])] {
        let listed = Set(makers.flatMap(\.1))
        let named = makers.map { maker in (maker.0, maker.1.compactMap(ConsoleCatalog.console)) }
        let others = ConsoleCatalog.all.filter { !listed.contains($0.id) }
        return named + (others.isEmpty ? [] : [(String(localized: "Others"), others)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("A home for your classics."),
                       message: Text("Choose only the systems you play."))
            ForEach(Self.groups, id: \.0) { maker, consoles in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: maker).groupHeader()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(consoles) { console in
                            ConsoleTile(console: console, model: model)
                        }
                    }
                }
            }
            RowGroup {
                ForEach(model.folderRows) { row in
                    FoundRow(title: Text(verbatim: row.found?.shortPath() ?? row.url.plainPath),
                             detail: Text(row.found.map(FoundList.folderLine) ?? String(localized: "Added by you")),
                             monospaced: true) {
                        Toggle(isOn: Binding(get: { model.keepsFolder(row.id) }, set: { model.setKeepsFolder(row.id, $0) })) {
                            Text("Watch this folder")
                        }
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                FoundRow(title: Text("ROM folder"),
                         detail: Text(model.romFolder ?? String(localized: "Cartouche only reads these folders."))) {
                    Button("Choose…") {
                        if let folder = GameFolders.choose() { model.chooseRomFolder(folder) }
                    }
                    .buttonStyle(.pill)
                }
            }
            ForEach(model.biosNotes.filter { !$0.isReady }, id: \.console.id) { status in
                BIOSNote(status: status, folder: model.consoles.biosFolder)
            }
            if let problem = model.consoleProblem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ConsoleTile: View {
    let console: Console
    let model: OnboardingModel

    var body: some View {
        let picked = model.isPicked(console)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button {
            model.toggle(console)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    ConsoleMarkView(id: console.id, size: 20).foregroundStyle(Color.accentColor)
                        .frame(height: 20)
                    Spacer(minLength: 4)
                    if picked {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.bottom, 4)
                Text(verbatim: console.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(verbatim: ConsolesStep.coreNames[console.core] ?? console.core)
                    .font(.system(size: 11)).foregroundStyle(Glass.label2)
                note.font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(picked ? Color.accentColor.opacity(0.12) : Glass.fill, in: shape)
            .overlay { if picked { shape.strokeBorder(Color.accentColor, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private var note: some View {
        let found = model.foundGames(console)
        let bios = console.bios != .none && model.isPicked(console) ? model.consoles.bios(console) : nil
        if let bios, !bios.isReady {
            Text(bios.message).foregroundStyle(.orange)
        } else if let core = model.setup.cores[console.id], core.working {
            Text("Downloading").foregroundStyle(Color.accentColor)
        } else if let core = model.setup.cores[console.id], core.problem != nil {
            Text("Failed").foregroundStyle(.red)
        } else if model.isAdded(console) {
            Text("Added").foregroundStyle(Glass.label2)
        } else if found > 0 {
            Text(found == 1 ? String(localized: "1 game found") : String(localized: "\(found) games found"))
                .foregroundStyle(Color.green)
        } else if console.bios != .none {
            Text("Needs BIOS").foregroundStyle(.orange)
        }
    }
}

private struct BIOSNote: View {
    let status: BIOSStatus
    let folder: URL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(status.console.name) needs a BIOS").font(.system(size: 13, weight: .semibold))
                Text("\(status.message). Copy it from your own console into the BIOS folder.")
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Show BIOS Folder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            .buttonStyle(.pill)
        }
        .padding(12)
        .groupBackground(tint: .orange)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Controller

private struct ControllerStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("Pick up and play."),
                       message: Text("Connect by Bluetooth or USB. No setup required."))
            ControllerDiagram(family: model.padFamily, state: model.padDiagramState,
                              target: { ControllerLayout.preset(model.padPreset).target(of: $0).label(model.padFamily) })
                .frame(maxWidth: .infinity)
            if !model.controllerConnected {
                Text("No controller connected — your choices apply when you plug one in.")
                    .font(.system(size: 12))
                    .foregroundStyle(Glass.label2)
            }
            OnboardingControllerOptions(model: model)
        }
        .onAppear { model.setDiagramVisible(true) }
        .onDisappear { model.setDiagramVisible(false) }
    }
}

struct OnboardingControllerOptions: View {
    @Bindable var model: OnboardingModel

    var body: some View {
            RowGroup {
                FoundRow(title: Text("Button glyphs"),
                         detail: Text("PlayStation shows ○△□×, Xbox shows ABXY."), stacked: true) {
                    Picker(selection: Binding<PadFamily>(
                        get: { model.padFamily },
                        set: { model.setPadGlyphs($0) })) {
                        Text("PlayStation").tag(PadFamily.playStation)
                        Text("Xbox").tag(PadFamily.xbox)
                        Text("Nintendo").tag(PadFamily.nintendo)
                    } label: { Text("Glyphs") }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                FoundRow(title: Text("Layout"),
                         detail: Text("Preview the layout. Customize each game in Controls."), stacked: true) {
                    Picker(selection: Binding<ControllerLayout.Preset>(
                        get: { model.padPreset },
                        set: { model.setPadPreset($0) })) {
                        ForEach(model.padPresets) { Text($0.title).tag($0) }
                    } label: { Text("Layout") }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                FoundRow(title: Text("Keyboard-only games"),
                         detail: Text("Play them with the controller — needs Accessibility later.")) {
                    Toggle(isOn: $model.controllerKeys) { Text("Play keyboard-only games with the controller") }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
    }
}

// MARK: Permissions, storage, privacy

private struct PermissionsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("Your Mac. Your choices."),
                       message: Text("Only the access you need, when you need it."))
            if !model.neededPermissions.isEmpty {
                RowGroup {
                    ForEach(model.neededPermissions) { permission in
                        FoundRow(title: Text(permission.title),
                                 detail: Text(permission.feature)) {
                            permissionTrailing(permission)
                        }
                    }
                }
            }
            RowGroup {
                FoundRow(title: Text("Games folder"),
                         detail: Text(model.gamesLocation.plainPath),
                         monospaced: true) {
                    Button("Change…") {
                        if let folder = GameFolders.choose() { model.chooseGamesFolder(folder) }
                    }
                    .buttonStyle(.pill)
                    .disabled(model.movingStorage)
                }
                if model.gamesLocationIsExternal {
                    FoundRow(title: Text("External disk"),
                             detail: Text("macOS may ask for Removable Volumes the first time Cartouche reads it.")) {
                        EmptyView()
                    }
                }
            }
            if let problem = model.storageProblem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            RowGroup {
                FoundRow(title: Text("Online lookups"),
                         detail: Text("Find covers and compatibility reports by game name.")) {
                    Toggle(isOn: Bindable(model.privacy).fetchMacReports) { Text("Online lookups") }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text("Your accounts and play history stay on this Mac. Nothing is shared automatically.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
        }
        .permissionExplanationsOptional(model.permissionFlow)
    }

    @ViewBuilder
    private func permissionTrailing(_ permission: Permission) -> some View {
        switch model.permissionState(permission) {
        case .allowed:
            Found(label: Text("Allowed"))
        case .denied:
            Button(Remedy.settingsButton) { model.permissionFlow?.center.openSettings(for: permission) }
                .buttonStyle(.pill)
        case .notAsked, .unknown:
            Button("Allow") { model.ask(permission) }
                .buttonStyle(.pillProminent)
        }
    }
}

extension View {
    // The explanation sheet needs a live flow; without one (tests) rows just read state.
    func permissionExplanationsOptional(_ flow: PermissionFlow?) -> some View {
        Group {
            if let flow { self.permissionExplanations(flow) } else { self }
        }
    }
}

// MARK: Ready

private struct ReadyStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("You’re ready to play."), message: Text("Keep exploring while setup finishes in the background."))
            if !model.readyTasks.isEmpty {
                RowGroup {
                    ForEach(model.readyTasks) { task in
                        FoundRow(title: Text(verbatim: task.title), detail: Text(verbatim: task.detail)) {
                            taskMark(task)
                        }
                    }
                }
            }
            if let game = model.readyGame {
                HStack(alignment: .center, spacing: 16) {
                    CoverView(game: game, override: model.library.coverOverride(for: game.id))
                        .frame(width: 96, height: game.coverShape == .square ? 96 : 144)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: game.name).font(.title3.weight(.semibold))
                        Text(game.status()).foregroundStyle(.secondary)
                        Button("Play") { model.playReadyGame() }
                            .prominentButton()
                            .controlSize(.large)
                            .accessibilityLabel(Text("Play \(game.name)"))
                    }
                }
                .padding(12)
                .groupBackground()
            }
            Text("Drop a game, an installer, an archive or ROMs anywhere in the window.")
                .font(.system(size: 12))
                .foregroundStyle(Glass.label2)
            Text("Every choice is available in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
        }
    }

    @ViewBuilder
    private func taskMark(_ task: OnboardingModel.ReadyTask) -> some View {
        switch task.state {
        case .done:
            Found(label: Text("Done"))
        case .working:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
        case .failed:
            Text("Failed").foregroundStyle(.red)
        }
    }
}
