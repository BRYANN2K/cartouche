
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GameFolders {

    static let key = "library.gameFolders"

    private(set) var paths: [String]
    @ObservationIgnored let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: Self.key) ?? []
    }

    var folders: [URL] { paths.map { URL(filePath: $0, directoryHint: .isDirectory) } }

    func add(_ folder: URL) {
        let path = folder.plainPath
        guard !paths.contains(path) else { return }
        paths.append(path)
        save()
    }

    func remove(_ folder: URL) {
        let path = folder.plainPath
        paths.removeAll { $0 == path }
        save()
    }

    private func save() {
        defaults.set(paths, forKey: Self.key)
    }

    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add Folder")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension URL {
    var plainPath: String {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

struct GameFoldersSection: View {
    @Bindable var folders: GameFolders
    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?

    var body: some View {
        Section {
            if folders.folders.isEmpty {
                Text("No game folders").foregroundStyle(.secondary)
            }
            ForEach(folders.folders, id: \.self) { folder in
                LabeledContent {
                    Button("Remove") { folders.remove(folder) }
                } label: {
                    Text(verbatim: folder.plainPath).font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    if let consoles {
                        Text(WatchedFolderState.text(folder.plainPath, count: consoles.folderCounts[folder.plainPath] ?? 0))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let consoles {
                Toggle("Add new games automatically", isOn: Binding(
                    get: { consoles.folderChoices.addAutomatically },
                    set: { on in Task { await consoles.setAddAutomatically(on) } }))
            }
            Button("Add Folder…") {
                if let folder = GameFolders.choose() { folders.add(folder) }
            }
        } header: {
            Text("Game Folders")
        } footer: {
            Text("Folders where you keep your own console games. Cartouche only reads them.")
        }
    }
}
