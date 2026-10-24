// Closing the sheet never stops an install.

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
            case .drop: DropStep(model: model)
            case .analysis: AnalysisStep(model: model)
            case .review:
                if model.isImport { ImportReviewStep(model: model) } else { ReviewStep(model: model) }
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
    @State private var targeted = false

    var body: some View {
        SheetHeader(title: Text("Install a Windows Game"),
                    message: Text("Choose the folder with the installer. Keep the .bin files next to setup.exe."))
        DropZone(title: Text("Drop a folder here"), choose: Text("Choose Folder…"), targeted: targeted, action: choose)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.analyze(url)
                return true
            } isTargeted: { targeted = $0 }
        Footer {
            Spacer()
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
        Text(model.isImport ? "Checking the Game" : "Checking the Installer").font(.system(size: 17, weight: .bold))
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
        .groupBackground()
        Footer {
            Button("Back") { model.back() }
            Spacer()
            if model.hasBlockingProblem { Button("Check Again") { model.checkAgain() } }
            Button("Continue") { model.toReview() }
                .keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
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
        Text("Ready to Install").font(.system(size: 17, weight: .bold))
        HStack(alignment: .top, spacing: 18) {
            InstallCover(appID: model.appID, name: model.gameName).frame(width: 140, height: 210)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.gameName).font(.title3.bold())
                if model.identificationViaSteam {
                    Text("Identified via Steam").font(.callout).foregroundStyle(.secondary)
                }
                if let analysis = model.analysis {
                    Text("\(analysis.scan.parts.count) parts, about \(InstallSheetModel.size(analysis.space.installed)) installed")
                        .foregroundStyle(.secondary)
                }
                GameSearch(model: model)
                Form {
                    Picker("Runner", selection: $model.runnerID) {
                        if model.runners.isEmpty { Text("None set up").tag(String?.none) }
                        ForEach(model.runners) { runner in
                            Text(verbatim: "\(runner.name) \(runner.displayVersion)").tag(Optional(runner.id))
                        }
                    }
                    LabeledContent("Install to") { Text(model.installDir).font(.callout.monospaced()) }
                    if model.analysis?.directUnpack != nil {
                        LabeledContent("Installer") { Text("Direct unpack") }
                        Text("Game files are unpacked directly. No installer window opens.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker("Installer", selection: $model.mode) {
                            Text("Guided").tag(InnoCommand.Mode.guided)
                            Text("Automatic").tag(InnoCommand.Mode.automatic)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.analysis?.unpacker != nil)
                        if model.analysis?.unpacker != nil {
                            Text("This installer unpacks its data with its own helper programs. It needs the guided mode and a short install path.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(model.mode == .guided ? "The installer window opens so you can pick languages and options."
                                                       : "No windows. Default options are used.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
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
            Button("Install") { model.install() }.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent).disabled(!model.canInstall)
        }
    }
}

// An installed game: nothing runs, the program is picked here and the folder stays where it is unless copied.
private struct ImportReviewStep: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        Text("Ready to Import").font(.system(size: 17, weight: .bold))
        HStack(alignment: .top, spacing: 18) {
            InstallCover(appID: model.appID, name: model.gameName).frame(width: 140, height: 210)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.gameName).font(.title3.bold())
                if let analysis = model.analysis {
                    Text(verbatim: "\(analysis.folder.lastPathComponent) · \(InstallSheetModel.size(model.gameBytes))")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                GameSearch(model: model)
                Form {
                    Picker("Runner", selection: $model.runnerID) {
                        if model.runners.isEmpty { Text("None set up").tag(String?.none) }
                        ForEach(model.runners) { runner in
                            Text(verbatim: "\(runner.name) \(runner.displayVersion)").tag(Optional(runner.id))
                        }
                    }
                    // Chosen in the drop sheet: shown, not asked again
                    if model.decided != nil, let exe = model.chosenExe {
                        LabeledContent("Starts with") {
                            Text(verbatim: ExePicker.relative(exe, to: model.programs?.installFolder))
                                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    // An extracted archive always moves into Cartouche's games folder: nothing to choose.
                    if !model.isExtracted {
                        if model.decided != nil {
                            LabeledContent("Game files") {
                                Text(model.storage == .inPlace ? "Use in Place" : "Copy into Cartouche")
                            }
                        } else {
                            Picker("Game files", selection: $model.storage) {
                                Text("Use in Place").tag(InstallSheetModel.Storage.inPlace)
                                Text("Copy into Cartouche").tag(InstallSheetModel.Storage.copy)
                            }
                            .pickerStyle(.radioGroup)
                        }
                        if model.storage == .inPlace && model.onExternalDrive {
                            Text("This drive must be connected to play.").font(.callout).foregroundStyle(.secondary)
                        } else if model.storage == .copy && !model.copyFits {
                            Text("Not enough space to copy the game.").font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.columns)
                if model.decided != nil {
                    Button("Change…") { model.changeChoices() }
                }
            }
        }
        if let programs = model.programs, model.decided == nil {
            Text("Which file starts the game?").font(.headline)
            ExePicker(candidates: programs.candidates, base: programs.installFolder, selection: $model.chosenExe)
        }
        Toggle("Show in Steam", isOn: $model.showInSteam)
        if model.runners.isEmpty {
            Text("No runner is set up for installs. Set one up in Runners first.").font(.callout).foregroundStyle(.red)
        }
        Footer {
            Button("Back") { model.back() }
            Spacer()
            Button("Import") { model.install() }.keyboardShortcut(.defaultAction).disabled(!model.canInstall)
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
            Text(job.request.importing == nil ? "Installing \(job.title)" : "Importing \(job.title)").font(.system(size: 17, weight: .bold))
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
                    Button("Continue in Background") { center.continueInBackground() }.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
                } else {
                    Spacer()
                    Button("Close") { model.close() }.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
                }
            }
        }
    }
}

// mm:ss for a boot's or an install's elapsed time.
enum InstallElapsed {
    static func format(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ProgressBody: View {
    let model: InstallSheetModel
    let job: InstallJob

    var body: some View {
        Text(phaseText).font(.headline)
        if job.phase == .preparing {
            bootBody
        } else if job.phase == .redistributables {
            ProgressView().controlSize(.small)
            ForEach(job.runtimeSteps) { step in
                if step.status == .skipped {
                    Label(String(localized: "\(step.label) was skipped"), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if step.status == .failed {
                    Label(String(localized: "\(step.label) could not be installed"), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if job.runtimeSteps.contains(where: { $0.status == .installing }) {
                Button("Skip") { model.skipRuntime() }
            }
        } else {
            ProgressView(value: job.progress.fraction)
        }
        if job.phase == .installing, job.request.importing != nil {
            Text("\(InstallSheetModel.size(job.progress.bytes)) of \(InstallSheetModel.size(job.request.expectedBytes))")
                .foregroundStyle(.secondary).monospacedDigit()
        } else if job.phase == .installing {
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
                        if job.canShowInstallerWindow {
                            Button("Show Installer Window") { model.showInstallerWindow() }
                        }
                        Button("Stop") { model.stop() }
                    }
                }
            } else if job.canShowInstallerWindow {
                Button("Show Installer Window") { model.showInstallerWindow() }
            }
        }
    }

    // The prefix's first boot has no fraction to show: a small spinner, the elapsed time, and its log.
    @ViewBuilder
    private var bootBody: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            if let started = job.bootStarted {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(InstallElapsed.format(from: started, to: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let log = job.bootLog {
                Button("Show Log") { NSWorkspace.shared.open(log) }
            }
        }
    }

    private var phaseText: String {
        switch job.phase {
        case .waiting: String(localized: "Waiting for the other install to finish")
        case .verifying: String(localized: "Checking files")
        case .preparing: String(localized: "Preparing Windows environment")
        case .redistributables:
            if let n = job.runtimeSteps.firstIndex(where: { $0.status == .installing }) {
                String(localized: "Installing \(job.runtimeSteps[n].label) runtime, \(n + 1) of \(job.runtimeSteps.count)")
            } else {
                String(localized: "Installing runtimes")
            }
        default: job.request.importing == nil ? String(localized: "Unpacking game files") : String(localized: "Copying game files")
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
        // A failed first boot has no diagnosis: plain retry, or a wiped prefix built from scratch.
        if job.diagnosis == nil, job.bootStarted != nil {
            HStack {
                Button("Try Again") { model.tryAgain() }
                Button("Recreate Prefix") { model.recreatePrefix() }
            }
        } else if job.directUnpackFailed, model.fixes.isEmpty {
            // A direct unpack that stopped without a fix to offer: Try Again runs the original setup.
            Button("Try Again") { model.tryAgain() }
        }
        if let diagnosis = job.diagnosis {
            if let detail = diagnosis.detail { Text(detail).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            if let explanation = diagnosis.explanation {
                Text(Self.text(explanation)).font(.callout)
            }
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
        case .missingPart: String(localized: "A part file the installer needs is missing")
        }
    }

    static func text(_ explanation: InstallDiagnosis.Explanation) -> String {
        switch explanation {
        case .decompressorMemory:
            String(localized: "The decompressor could not get the memory it asked for. It can also mean an archive error on this code.")
        case .decompressorData:
            String(localized: "The archive data or its header is damaged.")
        case .decompressorIO:
            String(localized: "The decompressor could not read the archive or write a file out.")
        case .missingPart:
            String(localized: "The extractor looked for a part file that is not there. The folder is missing a file.")
        case .diedBeforeWizard:
            String(localized: "The installer quit right after unpacking its helper programs, before showing its first page. A helper the runner could not load is the most likely cause.")
        case .helperFailed:
            String(localized: "One of the installer's own helper programs reported an error.")
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
        Text("Which file starts the game?").font(.system(size: 17, weight: .bold))
        if let job = model.job {
            if job.candidates.isEmpty {
                Text("No program was found in the install folder.").foregroundStyle(.secondary)
            } else {
                Text("Installed. These programs were created, the first one is the most likely.").foregroundStyle(.secondary)
                ExePicker(candidates: job.candidates, base: job.installFolder, selection: $model.chosenExe)
            }
            if let installed = job.unpackerPrepInstalled {
                Label(installed ? String(localized: "The installer's compatibility settings were applied") : String(localized: "The installer's compatibility settings could not be applied"),
                      systemImage: installed ? "checkmark" : "exclamationmark.triangle")
            }
            ForEach(job.runtimeSteps) { step in
                switch step.status {
                case .installed:
                    Label(String(localized: "\(step.label) installed"), systemImage: "checkmark")
                case .skipped:
                    Label(String(localized: "\(step.label) was skipped"), systemImage: "exclamationmark.triangle")
                case .failed:
                    Label(String(localized: "\(step.label) could not be installed"), systemImage: "exclamationmark.triangle")
                default: EmptyView()
                }
            }
            Toggle("Show in Steam", isOn: $model.showInSteam)
            if let problem = model.finishProblem { Text(problem).foregroundStyle(.red) }
            Footer {
                Spacer()
                Button("Continue") { model.confirmExe() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
                    .disabled(job.candidates.isEmpty)
            }
        }
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

private struct ExePicker: View {
    let candidates: [ExeDetector.Candidate]
    let base: URL?
    @Binding var selection: String?

    var body: some View {
        Picker("Program", selection: $selection) {
            ForEach(Array(candidates.enumerated()), id: \.element.path) { n, candidate in
                VStack(alignment: .leading) {
                    Text(Self.relative(candidate.path, to: base)).font(.body.monospaced())
                    Text(ExeStep.reason(candidate.source) + (n == 0 ? " · " + String(localized: "Recommended") : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .tag(Optional(candidate.path))
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    static func relative(_ path: String, to base: URL?) -> String {
        let prefix = (base?.standardizedFileURL.path(percentEncoded: false) ?? "") + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }
}

private struct ReadyStep: View {
    @Bindable var model: InstallSheetModel

    var body: some View {
        if let job = model.job {
            VStack(spacing: 12) {
                InstallCover(appID: job.request.appID, name: job.title).frame(width: 120, height: 180)
                Text("\(job.title) is ready").font(.system(size: 17, weight: .bold))
                if let outcome = model.steamOutcome ?? job.steamOutcome { Text(Self.steam(outcome)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            if job.request.importing == nil {
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
                    Text(model.cleanupMessage)
                }
            }
            Footer {
                Spacer()
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction).buttonStyle(.sheetProminent)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill2)
            Text(name).font(.headline).multilineTextAlignment(.center).padding(8).foregroundStyle(.secondary)
            if let url = appID.flatMap(GameCover.steam) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { CoverEdge(radius: 12) }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .accessibilityLabel(Text("\(name) cover"))
    }
}

private struct Footer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .buttonStyle(.sheet)
            .padding(.top, 6)
    }
}
