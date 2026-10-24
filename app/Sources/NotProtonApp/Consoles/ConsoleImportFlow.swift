import AppKit
import Observation
import RetroArchKit
import SwiftUI

@MainActor
@Observable
final class ConsoleImport {

    enum Step: Equatable { case drop, identify }

    struct Row: Identifiable, Equatable {
        let file: URL
        var found: Identification?
        var id: String { file.path(percentEncoded: false) }
    }

    private(set) var step: Step = .drop
    private(set) var rows: [Row] = []
    private(set) var checking = false
    var chosen: [String: String] = [:]

    @ObservationIgnored private let identifier: Identifier
    @ObservationIgnored private var work: Task<Void, Never>?

    init(identifier: Identifier) {
        self.identifier = identifier
    }

    func start(_ urls: [URL]) {
        work?.cancel()
        rows = []
        step = .identify
        checking = true
        let identifier = identifier
        work = Task { [weak self] in
            let files = await Task.detached { Identifier.files(in: urls) }.value
            guard let self, !Task.isCancelled else { return }
            self.rows = files.map { Row(file: $0) }
            self.chosen = [:]
            for file in files {
                if Task.isCancelled { return }
                let found = await identifier.identify(file)
                guard !Task.isCancelled else { return }
                if let i = rows.firstIndex(where: { $0.file == file }) { rows[i].found = found }
            }
            checking = false
        }
    }

    func finish() async { await work?.value }

    func reset() {
        work?.cancel()
        work = nil
        rows = []
        chosen = [:]
        checking = false
        step = .drop
    }

    var done: Bool { !checking && rows.allSatisfy { $0.found != nil } }

    var recognized: [Identification] { rows.compactMap(\.found).filter(\.isRecognized) }

    var games: [ConsoleGame] {
        rows.compactMap(\.found).compactMap { found in
            found.isRecognized ? found.game() : chosen[found.id].flatMap { found.game(console: $0) }
        }
    }

    var title: String {
        guard done else { return String(localized: "Identifying games…") }
        let n = recognized.count
        return n == 1 ? String(localized: "1 game identified") : String(localized: "\(n) games identified")
    }

    var addTitle: String {
        let n = games.count
        return n == 1 ? String(localized: "Add 1 Game") : String(localized: "Add \(n) Games")
    }

    static func line(_ found: Identification) -> String {
        guard found.isRecognized, let id = found.console, let by = found.identifiedBy else {
            return String(localized: "Not recognized")
        }
        let console = ConsoleCatalog.console(id)?.name ?? id
        switch by {
        case .checksum: return String(localized: "\(console), checksum match")
        case .discID: return String(localized: "\(console), disc ID")
        case .fileName: return String(localized: "\(console), file name match")
        case .chosen: return console
        }
    }

    func newConsoles(added: [Console]) -> [Console] {
        let ids = games.map(\.console).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ids.filter { id in !added.contains { $0.id == id } }.compactMap(ConsoleCatalog.console)
    }
}

struct ConsoleImportFlow: View {
    let center: ConsoleCenter
    let flow: ConsoleImport
    // Opened from Add Games: Back closes this sheet and Add Games shows again
    let back: (@MainActor () -> Void)?
    @State private var targeted = false
    @State private var adding = false
    @State private var addition: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(center: ConsoleCenter, flow: ConsoleImport? = nil, back: (@MainActor () -> Void)? = nil) {
        self.center = center
        self.flow = flow ?? center.importFlow
        self.back = back
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch flow.step {
            case .drop: dropStep(flow)
            case .identify: identifyStep(flow)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onDisappear { addition?.cancel(); flow.reset() }
    }

    @ViewBuilder
    private func dropStep(_ flow: ConsoleImport) -> some View {
        SheetHeader(title: Text("Add Console Games"),
                    message: Text("Drop your own game files or a folder. Zip, chd, cue and m3u work."))
        DropZone(title: Text("Drop files or a folder here"), choose: Text("Choose…"), targeted: targeted) {
            if let urls = Self.chooser() { flow.start(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            flow.start(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        Text("Games in your game folders are added automatically. Set them in Settings > Library.")
            .font(.system(size: 11))
            .foregroundStyle(Glass.label2)
            .padding(.horizontal, 4)
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.sheet)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func identifyStep(_ flow: ConsoleImport) -> some View {
        SheetHeader(title: Text(flow.title),
                    message: Text("Matched against the libretro database (No-Intro and Redump)."))
        ScrollView {
            VStack(spacing: 0) {
                ForEach(flow.rows) { row in
                    ImportRow(row: row, chosen: Binding(
                        get: { flow.chosen[row.id] ?? "" },
                        set: { flow.chosen[row.id] = $0.isEmpty ? nil : $0 }))
                    if row.id != flow.rows.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .groupBackground()
        }
        .softScrollEdges()
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(adding)
        let new = flow.done ? flow.newConsoles(added: center.added) : []
        if !new.isEmpty {
            Text(Self.alsoAdds(new))
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground(tint: .accentColor)
        }
        if adding {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(center.preparing.values.sorted().first ?? String(localized: "Preparing console games…"))
                    .font(.system(size: 12))
            }
        } else if let problem = center.problem {
            Text(problem).font(.system(size: 12)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button("Back") {
                if let back {
                    back()
                    dismiss()
                } else {
                    flow.reset()
                }
            }
            .buttonStyle(.sheet)
            .disabled(adding)
            Spacer()
            Button("Cancel") { addition?.cancel(); flow.reset(); dismiss() }
                .buttonStyle(.sheet)
                .keyboardShortcut(.cancelAction)
            Button(flow.addTitle) {
                let games = flow.games
                adding = true
                addition = Task {
                    await center.addGames(games)
                    adding = false
                    if !Task.isCancelled && center.problem == nil && games.allSatisfy({ center.game($0.id) != nil }) {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.sheetProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(adding || !flow.done || flow.games.isEmpty)
        }
        .padding(.top, 4)
    }

    static func alsoAdds(_ consoles: [Console]) -> String {
        let names = ListFormatter.localizedString(byJoining: consoles.map(\.name))
        let cores = ListFormatter.localizedString(byJoining: consoles.map(\.coreName).reduce(into: [String]()) {
            if !$1.isEmpty && !$0.contains($1) { $0.append($1) }
        })
        if cores.isEmpty { return String(localized: "Also adds \(names) to your consoles.") }
        return String(localized: "Also adds \(names) to your consoles, with \(cores).")
    }

    static var chooser: @MainActor () -> [URL]? = ConsoleImportFlow.openPanel

    static func openPanel() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose your own game files, or a folder of them.")
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

private struct ImportRow: View {
    let row: ConsoleImport.Row
    @Binding var chosen: String

    var body: some View {
        HStack(spacing: 10) {
            ConsoleMarkView(id: row.found?.console ?? "", size: 16)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Glass.fill2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.found?.name ?? row.file.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(row.found.map(ConsoleImport.line) ?? String(localized: "Checking…"))
                    .font(.system(size: 11)).foregroundStyle(Glass.label2).lineLimit(1)
            }
            Spacer()
            if let found = row.found {
                if found.isRecognized {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel(Text("Identified"))
                } else {
                    Picker("Console", selection: $chosen) {
                        Text("Choose console…").tag("")
                        ForEach(Self.order(found.candidates)) { console in
                            Text(verbatim: console.name).tag(console.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    static func order(_ candidates: [String]) -> [Console] {
        candidates.compactMap(ConsoleCatalog.console) + ConsoleCatalog.all.filter { !candidates.contains($0.id) }
    }
}
