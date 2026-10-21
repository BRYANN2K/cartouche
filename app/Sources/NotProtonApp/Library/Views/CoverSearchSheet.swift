// The Change Cover > Search Steam sheet: the name goes to Steam's public store
// search only when the online-lookups choice allows it. Picking a result stores
// the game's CDN cover as its override and keeps the app ID on the record.

import AppKit
import SwiftUI

struct CoverSearchSheet: View {
    let game: Game
    @Bindable var model: LibraryModel
    let choices: PrivacyChoices
    var lookup: SteamLookup = .standard

    @Environment(\.covers) private var covers
    @Environment(\.dismiss) private var dismiss

    @State private var term: String
    @State private var items: [SteamLookup.Item] = []
    @State private var searched = false
    @State private var searching = false
    @State private var picking: Int?

    init(game: Game, model: LibraryModel, choices: PrivacyChoices, lookup: SteamLookup = .standard) {
        self.game = game
        self.model = model
        self.choices = choices
        self.lookup = lookup
        _term = State(initialValue: game.name)
    }

    private var allowed: Bool { choices.fetchMacReports }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a Cover on Steam").font(.system(size: 17, weight: .bold))
            HStack {
                TextField("Game name", text: $term)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search") { search() }
                    .buttonStyle(.sheetProminent)
                    .disabled(!allowed || searching || term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            content
            HStack {
                Text("The game’s name is sent to Steam.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sheet)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 460)
        .task { search() }
    }

    @ViewBuilder
    private var content: some View {
        if !allowed {
            Text("Steam lookups are turned off in Settings > Privacy")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searching && items.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searched && items.isEmpty {
            Text("No games found on Steam.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items, id: \.appID) { item in
                Button { pick(item) } label: {
                    HStack(spacing: 12) {
                        Capsule(item: item, fetch: lookup.fetch)
                            .frame(width: 92, height: 35)
                        Text(item.name)
                            .lineLimit(2)
                        Spacer()
                        if picking == item.appID {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(picking != nil)
            }
            .listStyle(.plain)
        }
    }

    private func search() {
        let name = term.trimmingCharacters(in: .whitespaces)
        guard allowed, !searching, !name.isEmpty else { return }
        searching = true
        let lookup = lookup
        Task {
            let found = await lookup.search(name)
            guard !Task.isCancelled else { return }
            items = found.filter(\.isApp)
            searched = true
            searching = false
        }
    }

    private func pick(_ item: SteamLookup.Item) {
        picking = item.appID
        Task {
            let ok = await model.useSteamCover(item, for: game, covers: covers)
            if !ok { model.problem = String(localized: "Cartouche couldn’t download that cover.") }
            dismiss()
        }
    }
}

// The result's capsule image (Steam's tiny_image), fetched lazily like a cover.
private struct Capsule: View {
    let item: SteamLookup.Item
    let fetch: HTTPFetch.Fetch
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: item.appID) {
                guard let url = item.capsule,
                      let (data, status) = try? await fetch(QAEnvironment.url(url)),
                      status == 200, CoverStore.looksLikeImage(data) else { return }
                image = NSImage(data: data)
            }
            .accessibilityHidden(true)
    }
}
