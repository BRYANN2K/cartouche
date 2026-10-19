// The first launch, as a sheet over the library: Welcome, PC games, Consoles,
// Folders and privacy, Ready. Every step can be skipped.

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
            Divider()
            OnboardingFooter(model: model)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 660, height: 620)
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
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
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
                Text("Welcome back").font(.headline)
                Text("You were setting up \(step.title). Your choices are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Start Over", action: startOver)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
                .prominentButton()
        }
        .controlSize(.large)
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

// A title and its line, as each step opens
private struct StepHeader: View {
    let title: Text
    let message: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.font(.largeTitle.weight(.bold))
            message.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// One row of a grouped list: what it is, one line about it, and its state or action
private struct FoundRow<Trailing: View>: View {
    let title: Text
    var detail: Text?
    var monospaced = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(monospaced ? .body.monospaced().weight(.semibold) : .headline)
                if let detail {
                    detail.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct Found: View {
    let label: Text

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
            label.foregroundStyle(.secondary)
        }
    }
}

private struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
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
                FoundRow(title: Text(verbatim: "Steam"), detail: Text(Self.steamLine(steam))) {
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
        // In the language the rest of the line is in
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
                             detail: Text("Steam is not on this Mac. The Steam page of the library installs it.")) {
                        EmptyView()
                    }
                }
            }
            if case .failed(let message) = model.runnerPhase {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("You can skip this and play console games only.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            Button("Try Again") { Task { await model.downloadRunner() } }
        case .notInstalled, .none:
            Button("Download") { Task { await model.downloadRunner() } }
                .prominentButton()
        }
    }

    static func origin(_ build: RunnerManifest.Build) -> String {
        switch build.origin {
        case .cartouche: String(localized: "Free runner, built by Cartouche from CodeWeavers’ open-source code")
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

    // Product names of the recommended cores
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
                    Text(verbatim: maker).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
        Button {
            model.toggle(console)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: console.name).font(.callout.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if picked {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(verbatim: ConsolesStep.coreNames[console.core] ?? console.core)
                    .font(.caption).foregroundStyle(.secondary)
                note.font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .groupBackground(radius: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 2)
        }
        .disabled(model.addingConsoles)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private var note: some View {
        let found = model.foundGames(console)
        // Picked, a console that cannot start without its BIOS names the missing file
        let bios = console.bios != .none && model.isPicked(console) ? model.consoles.bios(console) : nil
        if let bios, !bios.isReady {
            Text(bios.message).foregroundStyle(.orange)
        } else if model.isAdded(console) {
            Text("Added").foregroundStyle(.secondary)
        } else if found > 0 {
            Text(found == 1 ? String(localized: "1 game found") : String(localized: "\(found) games found"))
                .foregroundStyle(Color.accentColor)
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
                Text("\(status.console.name) needs a BIOS").font(.headline)
                Text("\(status.message). Copy it from your own console into the BIOS folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Show BIOS Folder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
        }
        .padding(12)
        .groupBackground()
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
                }
            }
            RowGroup {
                FoundRow(title: Text("Fetch Mac reports from MacGamingDB"),
                         detail: Text("When you open a game, Cartouche asks MacGamingDB for its Mac reports. No account or Mac identifier is sent.")) {
                    Toggle(isOn: Bindable(model.privacy).fetchMacReports) { Text("Fetch Mac reports from MacGamingDB") }
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text("Cartouche asks for a permission the first time you use the feature that needs it.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
