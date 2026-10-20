// Steps follow mockup/launcher.html; closing never stops an install.

import AppKit
import InstallerKit
import SwiftUI
import UniformTypeIdentifiers

struct InstallSheet: View {

    @Bindable var center: InstallCenter

    private var model: InstallSheetModel { center.sheet }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .drop: DropStep(model: model, showConsoleGames: center.showConsoleGames)
            case .analysis: AnalysisStep(model: model)
            case .review: ReviewStep(model: model)
            case .installing: InstallingStep(center: center, model: model)
            case .chooseExe: ExeStep(model: model)
            case .ready: ReadyStep(model: model)
            }
        }
        .padding(22)
        .frame(width: model.step == .review || model.step == .installing ? 620 : 520)
        .onExitCommand { closeOrBackground() }
    }

    private func closeOrBackground() {
        if model.job?.isRunning == true { center.continueInBackground() } else { model.close() }
    }
}

// MARK: Steps

private struct DropStep: View {
    let model: InstallSheetModel
    var showConsoleGames: (@MainActor () -> Void)?
    @State private var targeted = false

    var body: some View {
        Text("Install a Windows Game").font(.title2.bold())
        if let showConsoleGames {
            Picker("Kind", selection: Binding(get: { AddGamesKind.windows }, set: { if $0 == .consoles { showConsoleGames() } })) {
                ForEach(AddGamesKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Text("Choose the folder with the installer. Keep the .bin files next to setup.exe.")
            .foregroundStyle(.secondary)
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Drop a folder here").font(.headline)
            Button("Choose Folder…", action: choose)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .secondary.opacity(0.4),
                                                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.analyze(url)
            return true
        } isTargeted: { targeted = $0 }
        Footer {
            Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder] + (UTType(filenameExtension: "exe").map { [$0] } ?? [])
        if panel.runModal() == .OK, let url = panel.url { model.analyze(url) }
    }
}

private struct AnalysisStep: View {
    let model: InstallSheetModel

    var body: some View {
        Text("Checking the Installer").font(.title2.bold())
        if let folder = model.dropped {
            Text(Analyzer.folder(for: folder).lastPathComponent).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        VStack(spacing: 0) {
            if let problem = model.readProblem {
                CheckRow(item: .init(id: "read", title: problem, detail: "", check: .failed))
            } else if model.analysis == nil {
                CheckRow(item: .init(id: "busy", title: String(localized: "Reading the installer…"), detail: "", check: .running(nil)))
            }
            ForEach(model.items) { item in
                CheckRow(item: item)
                if item.id != model.items.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        Footer {
            Button("Back") { model.back() }
            Spacer()
            if model.hasBlockingProblem { Button("Check Again") { model.checkAgain() } }
            Button("Continue") { model.toReview() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
    }
}

private struct CheckRow: View {
    let item: InstallSheetModel.Item

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon.frame(width: 18)
            if let id = item.cover { InstallCover(appID: id, name: item.title).frame(width: 24, height: 36) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium).foregroundStyle(color)
                if case .running(let fraction?) = item.check {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                } else if !item.detail.isEmpty {
                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch item.check {
        case .failed: .red
        case .warning: .orange
        default: .primary
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.check {
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
    }
}

private struct ReviewStep: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        Text("Ready to Install").font(.title2.bold())
        HStack(alignment: .top, spacing: 18) {
            InstallCover(appID: model.appID, name: model.gameName).frame(width: 140, height: 210)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.gameName).font(.title3.bold())
                if let analysis = model.analysis {
                    Text("\(analysis.scan.parts.count) parts, about \(InstallSheetModel.size(analysis.space.installed)) installed")
                        .foregroundStyle(.secondary)
                }
                GameSearch(model: model)
                Form {
                    Picker("Runner", selection: $model.runnerID) {
                        if model.runners.isEmpty { Text("None set up").tag(String?.none) }
                        ForEach(model.runners) { runner in
                            Text(verbatim: "\(runner.kind.name) \(runner.displayVersion)").tag(Optional(runner.id))
                        }
                    }
                    LabeledContent("Install to") { Text(model.installDir).font(.callout.monospaced()) }
                    Picker("Installer", selection: $model.mode) {
                        Text("Guided").tag(InnoCommand.Mode.guided)
                        Text("Automatic").tag(InnoCommand.Mode.automatic)
                    }
                    .pickerStyle(.segmented)
                    Text(model.mode == .guided ? "The installer window opens so you can pick languages and options."
                                               : "No windows. Default options are used.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .formStyle(.columns)
            }
        }
        Text("The installer's Visual C++ and DirectX packages are replaced by their Wine versions. Your Mac stays awake until it's done.")
            .font(.callout).foregroundStyle(.secondary)
        if model.runners.isEmpty {
            Text("No runner is set up for installs. Set one up in Runners first.").font(.callout).foregroundStyle(.red)
        }
        Footer {
            Button("Back") { model.back() }
            Spacer()
            Button("Install") { model.install() }.keyboardShortcut(.defaultAction).disabled(!model.canInstall)
        }
    }
}

// The match can be wrong: the user picks the game from the compatibility data.
private struct GameSearch: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Not this game? Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
            ForEach(model.results, id: \.appID) { entry in
                Button(entry.name) { model.pick(entry) }
                    .buttonStyle(.link)
            }
        }
    }
}

private struct InstallingStep: View {
    let center: InstallCenter
    let model: InstallSheetModel

    var body: some View {
        if let job = model.job {
            Text("Installing \(job.title)").font(.title2.bold())
            HStack(alignment: .top, spacing: 18) {
                InstallCover(appID: job.request.appID, name: job.title)
                    .saturation(job.phase == .installing || job.phase == .redistributables ? job.progress.fraction : 1)
                    .overlay {
                        if let appID = job.request.appID, job.phase == .installing || job.phase == .redistributables {
                            RevealCover(game: .steam(appID, name: job.title, installed: false),
                                        progress: CoverReveal.Progress(fraction: job.progress.fraction))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(width: 120, height: 180)
                VStack(alignment: .leading, spacing: 10) {
                    switch job.phase {
                    case .failed: FailureView(model: model, job: job)
                    case .stopped: Text("Installation stopped").font(.headline)
                    default: ProgressBody(model: model, job: job)
                    }
                }
            }
            Footer {
                if job.isRunning || job.phase == .waiting {
                    Button("Stop") { model.stop() }
                    Spacer()
                    Button("Continue in Background") { center.continueInBackground() }.keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct ProgressBody: View {
    let model: InstallSheetModel
    let job: InstallJob

    var body: some View {
        Text(phaseText).font(.headline)
        ProgressView(value: job.progress.fraction)
        if job.phase == .installing {
            Grid(alignment: .leading, horizontalSpacing: 24) {
                GridRow {
                    Text("Unpacked").foregroundStyle(.secondary)
                    Text("Speed").foregroundStyle(.secondary)
                    Text("Time left").foregroundStyle(.secondary)
                    Text("CPU").foregroundStyle(.secondary)
                }
                .font(.caption)
                GridRow {
                    Text(InstallSheetModel.size(job.progress.bytes))
                    Text(verbatim: "\(InstallSheetModel.size(Int64(job.progress.bytesPerSecond)))/s")
                    Text(timeLeft)
                    Text(verbatim: "\(Int(job.progress.cpu.rounded()))%")
                }
                .monospacedDigit()
            }
            if job.isStuck {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The installer seems stuck.").font(.headline).foregroundStyle(.orange)
                    Text("The folder has not grown for 5 minutes and the installer is idle.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Show Installer Window") { model.showInstallerWindow() }
                        Button("Stop") { model.stop() }
                    }
                }
            } else if job.inputs.mode == .guided {
                Button("Show Installer Window") { model.showInstallerWindow() }
            }
        }
    }

    private var phaseText: String {
        switch job.phase {
        case .waiting: String(localized: "Waiting for the other install to finish")
        case .verifying: String(localized: "Checking files")
        case .preparing: String(localized: "Preparing a new prefix")
        case .redistributables: String(localized: "Installing Visual C++ and DirectX")
        default: String(localized: "Unpacking game files")
        }
    }

    private var timeLeft: String {
        guard let seconds = job.progress.secondsLeft else { return "–" }
        if seconds < 60 { return String(localized: "Less than a minute") }
        let minutes = Int((seconds / 60).rounded())
        return String(localized: "\(minutes) min")
    }
}

private struct FailureView: View {
    let model: InstallSheetModel
    let job: InstallJob

    var body: some View {
        Text("The installation failed").font(.headline).foregroundStyle(.red)
        if let problem = job.problem {
            Text(problem)
        }
        if let diagnosis = job.diagnosis {
            if let detail = diagnosis.detail { Text(detail).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            if !diagnosis.causes.isEmpty {
                Text("Probable causes, most likely first:").font(.callout)
                ForEach(Array(diagnosis.causes.enumerated()), id: \.offset) { n, cause in
                    Text(verbatim: "\(n + 1). \(Self.text(cause))").font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.fixes, id: \.self) { fix in
                    Button(Self.title(fix)) { model.retry(fix) }
                }
            }
        }
    }

    static func text(_ cause: InstallDiagnosis.Cause) -> String {
        switch cause {
        case .memory: String(localized: "Not enough memory for the decompressors")
        case .path: String(localized: "A path the installer cannot handle")
        case .damagedFile: String(localized: "A damaged installer file")
        case .diskSpace: String(localized: "Not enough disk space")
        case .runner: String(localized: "The runner cannot run this installer")
        }
    }

    static func title(_ fix: RetryFix) -> String {
        switch fix {
        case .verifyFiles: String(localized: "Verify Files")
        case .fewerThreads: String(localized: "Retry with Fewer Threads")
        case .lessMemory: String(localized: "Retry with Less Memory")
        case .shortPath: String(localized: "Retry with a Short Path")
        case .otherRunner: String(localized: "Try Another Runner")
        }
    }
}

private struct ExeStep: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        Text("Which file starts the game?").font(.title2.bold())
        if let job = model.job {
            if job.candidates.isEmpty {
                Text("No program was found in the install folder.").foregroundStyle(.secondary)
            } else {
                Text("Installed. These programs were created, the first one is the most likely.").foregroundStyle(.secondary)
                Picker("Program", selection: $model.chosenExe) {
                    ForEach(Array(job.candidates.enumerated()), id: \.element.path) { n, candidate in
                        VStack(alignment: .leading) {
                            Text(relative(candidate.path, job)).font(.body.monospaced())
                            Text(Self.reason(candidate.source) + (n == 0 ? " · " + String(localized: "Recommended") : ""))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .tag(Optional(candidate.path))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            if let installed = job.redistributablesInstalled {
                let labels = ListFormatter.localizedString(byJoining: Redistributables.labels(job.redistributables))
                Label(installed ? String(localized: "\(labels) installed") : String(localized: "\(labels) could not be installed"),
                      systemImage: installed ? "checkmark" : "exclamationmark.triangle")
            }
            Toggle("Show in Steam", isOn: $model.showInSteam)
            if let problem = model.finishProblem { Text(problem).foregroundStyle(.red) }
            Footer {
                Spacer()
                Button("Continue") { model.confirmExe() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.candidates.isEmpty)
            }
        }
    }

    private func relative(_ path: String, _ job: InstallJob) -> String {
        let base = (job.installFolder?.standardizedFileURL.path(percentEncoded: false) ?? "") + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).lastPathComponent
    }

    static func reason(_ source: ExeDetector.Candidate.Source) -> String {
        switch source {
        case .shortcut: String(localized: "From the Start Menu shortcut")
        case .gogInfo: String(localized: "From the GOG game info")
        case .registry: String(localized: "Registered by the installer")
        case .launcher: String(localized: "Launcher from the publisher")
        case .largest: String(localized: "Largest program in the folder")
        }
    }
}

private struct ReadyStep: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        if let job = model.job {
            VStack(spacing: 12) {
                InstallCover(appID: job.request.appID, name: job.title).frame(width: 120, height: 180)
                Text("\(job.title) is ready").font(.title2.bold())
                if let outcome = model.steamOutcome { Text(Self.steam(outcome)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            HStack {
                switch model.cleanup {
                case .done(let bytes):
                    Label("Installer files moved to the Trash. \(InstallSheetModel.size(bytes)) freed.", systemImage: "checkmark")
                case .failed(let problem):
                    Text(problem).foregroundStyle(.red)
                default:
                    Text("Delete the installer files and free \(InstallSheetModel.size(job.request.installerBytes))")
                    Spacer()
                    Button("Delete…") { model.requestCleanup() }
                }
            }
            .confirmationDialog(
                "Move the installer files to the Trash?",
                isPresented: Binding(get: { model.cleanup == .confirming }, set: { if !$0 && model.cleanup == .confirming { model.cleanup = .idle } })
            ) {
                Button("Move to Trash", role: .destructive) { model.confirmCleanup() }
                Button("Cancel", role: .cancel) { model.cleanup = .idle }
            } message: {
                Text("setup.exe and its \(job.request.installerFiles.count - 1) other files go to the Trash. The installed game is not touched.")
            }
            Footer {
                Spacer()
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    static func steam(_ outcome: SteamShortcuts.Outcome) -> String {
        switch outcome {
        case .added, .alreadyThere: String(localized: "It is in Steam's library too.")
        case .steamRunning: String(localized: "Steam is open, so the shortcut was not added. Quit Steam and install again to add it.")
        case .noAccount: String(localized: "No Steam account was found on this Mac, so no shortcut was added.")
        case .failed(let reason): reason
        }
    }
}

// MARK: Pieces

// Steam's portrait art when the game is known; otherwise its name.
private struct InstallCover: View {
    let appID: Int?
    let name: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            Text(name).font(.headline).multilineTextAlignment(.center).padding(8).foregroundStyle(.secondary)
            if let url = appID.flatMap(GameCover.steam) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(Text("\(name) cover"))
    }
}

private struct Footer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack { content }.padding(.top, 6)
    }
}
