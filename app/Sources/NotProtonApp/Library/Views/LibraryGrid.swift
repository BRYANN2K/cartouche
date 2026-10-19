import SwiftUI

struct LibraryGrid: View {
    @Bindable var model: LibraryModel
    let sections: [LibrarySection]
    let actions: GameActionRunner

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var droppedCover: (game: Game, image: URL)?

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let store = model.expiredStore {
                    ExpiredBanner(source: store)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = section.title {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(title).font(.title3.weight(.semibold))
                                Text(String(section.games.count)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: section.shape == .square ? 170 : 150, maximum: 220),
                                                     spacing: 18, alignment: .top)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(section.games) { game in
                                card(game).transition(motion.entrance)
                            }
                        }
                    }
                }
            }
            .padding(20)
            // Games come and go with a spring, or with no animation under Reduce Motion
            .animation(motion.grid, value: sections)
        }
        .confirmationDialog(
            Text("Use this image as the cover of \(droppedCover?.game.name ?? "")?"),
            isPresented: Binding(get: { droppedCover != nil }, set: { if !$0 { droppedCover = nil } })
        ) {
            Button("Use as Cover") {
                if let drop = droppedCover { model.setCover(drop.image, for: drop.game.id) }
                droppedCover = nil
            }
            Button("Cancel", role: .cancel) { droppedCover = nil }
        } message: {
            Text("It replaces the cover from Steam until you choose Use the Original Cover.")
        }
    }

    private func card(_ game: Game) -> some View {
        GameCard(
            game: game,
            isSelected: model.selectedGameID == game.id,
            isFavorite: model.isFavorite(game.id),
            override: model.coverOverride(for: game.id),
            onSelect: { model.select(game.id) },
            onFavorite: { model.toggleFavorite(game.id) },
            onDropCover: { droppedCover = (game, $0) },
            menu: { GameMenu.items(for: game, in: model) },
            perform: { actions.perform($0, on: game) }
        )
    }
}

struct ExpiredBanner: View {
    let source: GameSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your \(source.name) session expired").font(.headline)
                Text("Your games still play. Sign in again to download and update them.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Store sign-in comes with P10
            Button("Sign In Again") {}
                .prominentButton()
                .disabled(true)
        }
        .padding(14)
        .groupBackground()
    }
}
