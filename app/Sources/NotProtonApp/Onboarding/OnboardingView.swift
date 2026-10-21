
import AppKit
import RetroArchKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: model.step)
                .padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.resumed {
                        ResumeBanner(step: model.step) { model.startOver() }
                    }
                    step
                        .transition(Motion(reduceMotion: reduceMotion).entrance)
                        .id(model.step)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .softScrollEdges()
            OnboardingFooter(model: model)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 660, height: 620)
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        .task { await model.prepare() }
        .animation(Motion(reduceMotion: reduceMotion).panel, value: model.step)
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .pcGames: PCGamesStep(model: model)
        case .consoles: ConsolesStep(model: model)
        case .folders: FoldersStep(model: model)
        case .ready: ReadyStep(model: model)
        }
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
        HStack(spacing: 10) {
            switch model.step {
            case .welcome:
                Button("Skip Setup") { model.skipAll() }
            case .ready:
                EmptyView()
            default:
                Button("Skip") { model.skip() }
                    .disabled(!model.canContinue)
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .disabled(!model.canContinue)
            }
            primary
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.sheetProminent)
        }
        .buttonStyle(.sheet)
    }

    @ViewBuilder
    private var primary: some View {
        switch model.step {
        case .welcome:
            Button("Set Up") { model.next() }
        case .consoles where !model.consolesToAdd.isEmpty:
            Button(model.consolesToAdd.count == 1 ? String(localized: "Add 1 Console")
                                                  : String(localized: "Add \(model.consolesToAdd.count) Consoles")) {
                Task { await model.addConsoles() }
            }
            .disabled(model.addingConsoles)
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
            title.font(.system(size: 22, weight: .bold)).tracking(-0.44)
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let mark { PlatformMarkView(mark: mark).foregroundStyle(Color.accentColor) }
            VStack(alignment: .leading, spacing: 2) {
                title.font(monospaced ? .system(size: 12, weight: .medium).monospaced() : .system(size: 13, weight: .medium))
                if let detail {
                    detail.font(.system(size: 12)).foregroundStyle(Glass.label2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
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
            StepHeader(title: Text("Welcome to Cartouche"), message: Text("Here is what’s already on this Mac."))
            if let found = model.findings {
                if found.isEmpty {
                    Text("Nothing to bring in yet. The next steps set up Windows games and consoles.")
                        .foregroundStyle(.secondary)
                } else {
                    FoundList(found: found)
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

// MARK: PC games

private struct PCGamesStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("PC games"),
                       message: Text("Windows games run through a free runner. Steam games also get Steam Play."))
            RowGroup {
                if let build = model.runner {
                    FoundRow(title: Text(verbatim: build.title), detail: Text(Self.origin(build))) {
                        runnerState
                    }
                }
                if model.findings?.steam != nil {
                    SteamStepRow(step: model.steamStep)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                } else {
                    FoundRow(title: Text(verbatim: "Steam"),
                             detail: Text("Steam is not on this Mac. The Steam page of the library installs it."),
                             mark: .steam) {
                        EmptyView()
                    }
                }
            }
            if case .failed(let message) = model.runnerPhase {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
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
            ProgressView().controlSize(.small).accessibilityLabel(Text("Downloading"))
        case .failed:
            Button("Try Again") { Task { await model.downloadRunner() } }.buttonStyle(.pill)
        case .notInstalled, .none:
            Button("Download") { Task { await model.downloadRunner() } }
                .buttonStyle(.pillProminent)
        }
    }

    static func origin(_ build: RunnerManifest.Build) -> String {
        switch build.origin {
        case .cartouche: String(localized: "Free runner, built by Cartouche from CodeWeavers’ open-source code. Best for games: D3DMetal and DXMT.")
        case .winehq: String(localized: "Free runner, the official WineHQ build")
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
            StepHeader(title: Text("Consoles"),
                       message: Text("Consoles with games in your folders are already picked. Only their cores are downloaded."))
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
            ForEach(model.biosNotes.filter { !$0.isReady }, id: \.console.id) { status in
                BIOSNote(status: status, folder: model.consoles.biosFolder)
            }
            if model.addingConsoles {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading cores…").foregroundStyle(.secondary)
                }
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
        .disabled(model.addingConsoles)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private var note: some View {
        let found = model.foundGames(console)
        let bios = console.bios != .none && model.isPicked(console) ? model.consoles.bios(console) : nil
        if let bios, !bios.isReady {
            Text(bios.message).foregroundStyle(.orange)
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

// MARK: Folders and privacy

private struct FoldersStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("Folders and privacy"), message: Text("Where your games are, and what stays on this Mac."))
            RowGroup {
                ForEach(model.folderRows) { row in
                    FoundRow(title: Text(verbatim: row.found?.shortPath() ?? row.url.plainPath),
                             detail: Text(row.found.map(FoundList.folderLine) ?? String(localized: "Added by you")),
                             monospaced: true) {
                        Toggle(isOn: Binding(get: { model.keepsFolder(row.id) }, set: { model.setKeepsFolder(row.id, $0) })) {
                            Text("Use this folder")
                        }
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                FoundRow(title: Text("Game folders"),
                         detail: Text(model.folderRows.isEmpty ? String(localized: "No game folder found. Add the one where you keep your own console games.")
                                                               : String(localized: "Cartouche only reads these folders."))) {
                    Button("Add Folder…") {
                        if let folder = GameFolders.choose() { model.addFolder(folder) }
                    }
                    .buttonStyle(.pill)
                }
            }
            RowGroup {
                FoundRow(title: Text("Fetch Mac reports from MacGamingDB"),
                         detail: Text("When you open a game, Cartouche asks MacGamingDB for its Mac reports. When a Windows game has no cover, its name may be looked up in the Steam store. No account or Mac identifier is sent.")) {
                    Toggle(isOn: Bindable(model.privacy).fetchMacReports) { Text("Fetch Mac reports from MacGamingDB") }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text("Cartouche asks for a permission the first time you use the feature that needs it.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
        }
    }
}

// MARK: Ready

private struct ReadyStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: Text("You’re set"), message: Text(model.readySummary))
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
            Text("Everything you skipped is in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Glass.label2)
        }
    }
}
