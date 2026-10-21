import AppKit
import RetroArchKit
import SwiftUI

// Shown over the whole library window while files are dragged over it
struct DropOverlay: View {
    let targeted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if targeted {
                RoundedRectangle(cornerRadius: Glass.panelRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(reduceTransparency ? 0.18 : 0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: Glass.panelRadius, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    }
                    .padding(Glass.inset)
                    .transition(.opacity)
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop to add to Cartouche")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Installers, game folders, archives and console games")
                        .font(.system(size: 12))
                        .foregroundStyle(Glass.label2)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .floatingPanel(radius: 22)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: targeted)
        .accessibilityHidden(!targeted)
    }
}

struct AddGamesDropSheet: View {
    let add: ([URL]) -> Void
    @State private var targeted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: Text("Add Games"),
                        message: Text("Cartouche detects what you add automatically."))
            DropZone(title: Text("Drop a game, an installer, an archive or ROMs"),
                     choose: Text("Choose…"), targeted: targeted, action: choose)
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    add(urls)
                    return true
                } isTargeted: { targeted = $0 }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sheet)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

struct DropSheet: View {
    @Bindable var model: DropModel
    var actions = DropActions()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .detecting(let progress):
                DetectingStep(progress: progress) { model.cancel() }
            case .result(let result):
                ResultStep(result: result, model: model, actions: actions, done: { model.cancel() })
            case nil:
                EmptyView()
            }
        }
        .padding(22)
        .frame(width: 560)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.phase)
    }
}

private struct DetectingStep: View {
    let progress: DropProgress?
    let cancel: () -> Void

    var body: some View {
        if let progress {
            SheetHeader(title: Text("Extracting…"), message: Text(verbatim: progress.fileName))
            VStack(alignment: .leading, spacing: 6) {
                ActivityBar(fraction: progress.fraction, height: 6)
                    .accessibilityLabel(Text("Extraction progress"))
                HStack {
                    Text("\(DownloadSummary.size(progress.bytesDone)) of \(DownloadSummary.size(progress.bytesTotal))")
                    Spacer()
                    if let left = progress.secondsLeft { Text(Self.timeLeft(left)) }
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Glass.label2)
            }
        } else {
            SheetHeader(title: Text("Looking at what you dropped…"),
                        message: Text("Cartouche checks for installers, installed games and console games."))
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel(Text("Detecting"))
        }
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .buttonStyle(.sheet)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 4)
    }

    static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "Less than a minute") }
        return String(localized: "\(Int((seconds / 60).rounded())) min left")
    }
}

private struct ResultStep: View {
    let result: DropResult
    @Bindable var model: DropModel
    let actions: DropActions
    let done: () -> Void

    var body: some View {
        switch result {
        case .installer(let installer):
            SheetHeader(title: Text("Windows installer"),
                        message: Text("Cartouche checks its files, then installs it with a runner."))
            ScrollView {
                InstallerCard(installer: installer)
            }
            .softScrollEdges()
            .fixedSize(horizontal: false, vertical: true)
            footer(primary: Text("Continue")) { actions.install(installer) }
        case .installedGame(let game):
            SheetHeader(title: Text("Installed game, ready to import"),
                        message: Text("Nothing is installed: Cartouche runs the game from its folder."))
            InstalledGameCard(game: game, chosenExe: $model.chosenExe, storage: $model.storage)
            footer(primary: Text("Add to Library"), disabled: model.chosenExe == nil) {
                if let exe = model.chosenExe { actions.importGame(game, exe, model.storage) }
            }
        case .roms(let roms):
            SheetHeader(title: Text(Self.romsTitle(roms.count)),
                        message: Text("Matched against the libretro database (No-Intro and Redump)."))
            ScrollView {
                ROMGroups(roms: roms, addConsole: actions.addConsole)
            }
            .softScrollEdges()
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            footer(primary: Text(Self.addTitle(roms.count)), disabled: roms.count == 0) { actions.addROMs(roms) }
        case .mixed(let parts):
            SheetHeader(title: Text("Several kinds of games"),
                        message: Text("Each kind goes where it belongs. Add them one kind at a time."))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        MixedPart(part: part, actions: actions)
                    }
                }
            }
            .softScrollEdges()
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.sheetProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        case .failed(let failure):
            FailureView(failure: failure, chooseAnother: actions.chooseAnother, close: done)
        }
    }

    private func footer(primary: Text, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: done)
                .buttonStyle(.sheet)
                .keyboardShortcut(.cancelAction)
            Button(action: action) { primary }
                .buttonStyle(.sheetProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
        .padding(.top, 4)
    }

    static func romsTitle(_ n: Int) -> String {
        n == 1 ? String(localized: "1 console game") : String(localized: "\(n) console games")
    }

    static func addTitle(_ n: Int) -> String {
        n == 1 ? String(localized: "Add 1 Game") : String(localized: "Add \(n) Games")
    }
}

private struct InstallerCard: View {
    let installer: DroppedInstaller

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: installer.name).font(.system(size: 13, weight: .semibold))
                Text(verbatim: installer.setup.lastPathComponent)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Glass.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if installer.parts > 1 {
                Text("\(installer.parts) parts").font(.system(size: 12)).foregroundStyle(Glass.label2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
        .accessibilityElement(children: .combine)
    }
}

private struct InstalledGameCard: View {
    let game: DroppedInstalledGame
    @Binding var chosenExe: URL?
    @Binding var storage: GameStorage

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverView(game: Game(id: "drop:\(game.folder.path(percentEncoded: false))", source: .installer,
                                 name: game.name, steamAppID: game.steamAppID, installed: true))
                .aspectRatio(CoverShape.portrait.aspectRatio, contentMode: .fit)
                .frame(width: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { CoverEdge(radius: 12) }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: game.name).font(.system(size: 17, weight: .bold)).tracking(-0.17)
                    Text(verbatim: game.folder.path(percentEncoded: false))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Glass.label2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 8) {
                    PanelRow(title: Text("Starts with")) {
                        Picker("Starts with", selection: $chosenExe) {
                            ForEach(game.executables, id: \.self) { exe in
                                Text(verbatim: relative(exe)).tag(Optional(exe))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    PanelRow(title: Text("Storage")) {
                        Picker("Storage", selection: $storage) {
                            ForEach(GameStorage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text(storage == .inPlace
                         ? "The game stays where it is. Cartouche only adds it to the library."
                         : "A copy goes into Cartouche’s games folder, \(DownloadSummary.size(game.bytes)). The original is not touched.")
                        .font(.system(size: 12))
                        .foregroundStyle(Glass.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .groupBackground()
                if game.onExternalDrive && storage == .inPlace {
                    Banner(tint: .orange, symbol: "externaldrive",
                           title: Text("On an external drive"),
                           detail: Text("The game plays only while this drive is connected.")) { EmptyView() }
                }
            }
        }
    }

    private func relative(_ exe: URL) -> String {
        let base = game.folder.standardizedFileURL.path(percentEncoded: false)
        let path = exe.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : exe.lastPathComponent
    }
}

private struct ROMGroups: View {
    let roms: DroppedROMs
    let addConsole: @MainActor (String) -> Void

    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(roms.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ConsoleMarkView(id: group.console, size: 14).foregroundStyle(Color.accentColor)
                        Text(verbatim: ConsoleCatalog.console(group.console)?.name ?? group.console)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Glass.label2)
                        Text(verbatim: "\(group.files.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Glass.label3)
                        Spacer()
                        if consoles?.isAdded(group.console) == false {
                            Button("Add Console") { addConsole(group.console) }.buttonStyle(.pill)
                        }
                    }
                    .padding(.horizontal, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    FileList(files: group.files)
                }
            }
            if !roms.unknown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not recognized").groupHeader()
                    FileList(files: roms.unknown, dimmed: true)
                }
            }
        }
    }
}

private struct FileList: View {
    let files: [URL]
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                if index > 0 { Divider().overlay(Glass.separator) }
                Text(verbatim: dimmed ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(dimmed ? Glass.label2 : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .groupBackground()
    }
}

private struct MixedPart: View {
    let part: DropResult
    let actions: DropActions

    var body: some View {
        switch part {
        case .installer(let installer):
            section(Text("Windows installer"), action: Text("Continue")) { actions.install(installer) } content: {
                InstallerCard(installer: installer)
            }
        case .installedGame(let game):
            section(Text("Installed game"), action: Text("Import…")) {
                actions.importGame(game, game.executables.first ?? game.folder, .inPlace)
            } content: {
                InstallerCard(installer: DroppedInstaller(setup: game.folder, name: game.name, parts: 0))
            }
        case .roms(let roms):
            section(Text(ResultStep.romsTitle(roms.count)), action: Text(ResultStep.addTitle(roms.count))) {
                actions.addROMs(roms)
            } content: {
                ROMGroups(roms: roms, addConsole: actions.addConsole)
            }
        case .mixed, .failed:
            EmptyView()
        }
    }

    private func section<Content: View>(_ title: Text, action: Text, perform: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                title.font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: perform) { action }.buttonStyle(.pillProminent)
            }
            .padding(.horizontal, 4)
            content()
        }
    }
}

private struct FailureView: View {
    let failure: DropFailure
    let chooseAnother: @MainActor () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                SheetHeader(title: title, message: message)
            }
            HStack(spacing: 8) {
                if let item = failure.item {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item]) }
                        .buttonStyle(.sheet)
                }
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.sheet)
                    .keyboardShortcut(.cancelAction)
                Button("Choose Another File…") { chooseAnother() }
                    .buttonStyle(.sheetProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private var symbol: String {
        switch failure {
        case .detectionUnavailable: "exclamationmark.triangle"
        case .passwordProtected: "lock"
        case .unsupportedArchive, .damagedArchive: "doc.zipper"
        case .missingVolume: "puzzlepiece"
        case .insufficientSpace: "internaldrive"
        case .nothingRecognized: "questionmark.folder"
        }
    }

    private var title: Text {
        switch failure {
        case .detectionUnavailable: Text("Game detection is unavailable")
        case .passwordProtected: Text("This archive needs a password")
        case .unsupportedArchive: Text("Cartouche can’t open this kind of archive")
        case .damagedArchive: Text("This archive is damaged")
        case .missingVolume(_, let name): Text("\(name) is missing")
        case .insufficientSpace: Text("Not enough disk space")
        case .nothingRecognized: Text("No game found here")
        }
    }

    private var message: Text {
        switch failure {
        case .detectionUnavailable:
            Text("Game detection is not available in this build. No files were changed.")
        case .passwordProtected(let url):
            Text("Extract \(url.lastPathComponent) with its password in Finder or another app, then drop the folder.")
        case .unsupportedArchive(let url):
            Text("\(url.lastPathComponent) is not a zip, 7z, rar, tar or disc image. Extract it first, then drop the folder.")
        case .damagedArchive(let url):
            Text("\(url.lastPathComponent) could not be read to the end. Download it again, then drop it here.")
        case .missingVolume(let url, let name):
            Text("Put \(name) in the same folder as \(url.lastPathComponent), then drop the archive again.")
        case .insufficientSpace(let url, let needed, let free):
            if needed > 0 {
                Text("Extracting \(url.lastPathComponent) needs about \(DownloadSummary.size(needed)) free on this drive; \(DownloadSummary.size(free)) is free.")
            } else {
                Text("The drive ran out of space while extracting \(url.lastPathComponent).")
            }
        case .nothingRecognized:
            Text("Cartouche found no installer, installed Windows game or console game in what you dropped.")
        }
    }
}
