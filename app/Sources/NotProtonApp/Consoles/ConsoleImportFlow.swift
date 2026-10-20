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
    @Binding var kind: AddGamesKind
    let flow: ConsoleImport
    @State private var targeted = false
    @Environment(\.dismiss) private var dismiss

    init(center: ConsoleCenter, kind: Binding<AddGamesKind>, flow: ConsoleImport? = nil) {
        self.center = center
        _kind = kind
        self.flow = flow ?? center.importFlow
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
        .onDisappear { flow.reset() }
    }

    private var kindPicker: some View {
        Picker("Kind", selection: Binding(get: { kind }, set: { new in
            guard new == .windows, let library = center.library else {
                kind = new
                return
            }
            flow.reset()
            library.addGames = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                library.addGames = .windows
            }
        })) {
            ForEach(AddGamesKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private func dropStep(_ flow: ConsoleImport) -> some View {
        Text("Add Games").font(.title2.weight(.bold))
        kindPicker
        Text("Drop your own game files or a folder. Zip, chd, cue and m3u work.")
            .foregroundStyle(.secondary)
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Drop files or a folder here").font(.headline)
            Button("Choose…") {
                if let urls = Self.chooser() { flow.start(urls) }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        }
        .dropDestination(for: URL.self) { urls, _ in
            flow.start(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        Text("Games in your game folders are added automatically. Set them in Settings > Library.")
            .font(.callout)
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func identifyStep(_ flow: ConsoleImport) -> some View {
        Text(flow.title).font(.title2.weight(.bold))
        Text("Matched against the libretro database (No-Intro and Redump).")
            .foregroundStyle(.secondary)
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
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        let new = flow.done ? flow.newConsoles(added: center.added) : []
        if !new.isEmpty {
            Text(Self.alsoAdds(new))
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        HStack {
            Button("Back") { flow.reset() }
            Spacer()
            Button("Cancel") { flow.reset(); dismiss() }.keyboardShortcut(.cancelAction)
            Button(flow.addTitle) {
                let games = flow.games
                dismiss()
                Task { await center.addGames(games) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.done || flow.games.isEmpty)
        }
    }

    static func alsoAdds(_ consoles: [Console]) -> String {
        let names = ListFormatter.localizedString(byJoining: consoles.map(\.name))
        let cores = ListFormatter.localizedString(byJoining: consoles.map(\.coreName).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        })
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
            ConsoleGlyphView(glyph: row.found?.console.flatMap(ConsoleCatalog.console)?.glyph ?? .cartridge)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.found?.name ?? row.file.lastPathComponent).lineLimit(1)
                Text(row.found.map(ConsoleImport.line) ?? String(localized: "Checking…"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
