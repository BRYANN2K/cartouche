import SwiftUI

struct LibraryGrid: View {
    @Bindable var model: LibraryModel
    let sections: [LibrarySection]
    let actions: GameActionRunner
    var compat: CompatibilityModel?

    @Environment(ConsoleCenter.self) private var consoles: ConsoleCenter?
    @Environment(ControlsCenter.self) private var controls: ControlsCenter?
    @Environment(StoreCenter.self) private var stores: StoreCenter?
    @State private var droppedCover: (game: Game, image: URL)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let store = model.expiredStore {
                    ExpiredBanner(source: store)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if let title = section.title {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(title).font(.system(size: 13, weight: .bold))
                                Text(String(section.games.count))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Glass.label3)
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16, alignment: .top)],
                                  alignment: .leading, spacing: 22) {
                            ForEach(section.games) { game in
                                card(game)
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 24, trailing: 16))
        }
        .softScrollEdges(top: Glass.toolbarHeight + 24, bottom: 24)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { controls?.couch.gridWidth = $0 }
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
            menu: { GameMenu.items(for: game, in: model, stores: stores, consoles: consoles) },
            perform: { actions.perform($0, on: game) },
            antiCheatBlocked: game.steamAppID.flatMap { compat?.record(appID: $0) }
                .flatMap(AntiCheatSummary.init(record:))?.level == .blocked
        )
    }
}

struct ExpiredBanner: View {
    let source: GameSource
    @Environment(StoreCenter.self) private var stores: StoreCenter?

    var body: some View {
        Banner(tint: .orange, symbol: "exclamationmark.triangle.fill",
               title: Text("Your \(source.name) session expired"),
               detail: Text("Your games still play. Sign in again to download and update them.")) {
            Button("Sign In Again") {
                if let stores { Task { await stores.beginSignIn(source) } }
            }
            .buttonStyle(.pillProminent)
            .disabled(stores == nil)
        }
    }
}

// The mockup's .banner: a tinted card with an icon, two lines and an action
struct Banner<Actions: View>: View {
    let tint: Color
    let symbol: String
    let title: Text
    let detail: Text
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.system(size: 13, weight: .semibold))
                detail.font(.system(size: 12)).foregroundStyle(Glass.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions().frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .groupBackground(tint: tint)
        .accessibilityElement(children: .contain)
    }
}
