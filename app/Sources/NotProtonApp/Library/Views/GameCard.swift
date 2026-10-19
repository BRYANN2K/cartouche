import SwiftUI

// The game menu as SwiftUI menu content, for the context menu, the Game menu and More
struct GameMenuContent: View {
    let items: [GameMenuItem]
    let perform: (GameAction) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isDivider {
                Divider()
            } else if !item.children.isEmpty || item.action == nil {
                Menu(item.title) {
                    GameMenuContent(items: item.children, perform: perform)
                }
                .disabled(item.disabled)
            } else if item.checked {
                Toggle(item.title, isOn: Binding(get: { true }, set: { _ in item.action.map(perform) }))
            } else {
                Button(item.title, role: item.destructive ? .destructive : nil) { item.action.map(perform) }
                    .disabled(item.disabled)
                    .shortcut(item.shortcut)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func shortcut(_ shortcut: Shortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.key == "\r" ? .return : KeyEquivalent(Character(shortcut.key)),
                             modifiers: shortcut.command ? .command : [])
        } else {
            self
        }
    }
}

struct GameCard: View {
    let game: Game
    let isSelected: Bool
    let isFavorite: Bool
    let override: URL?
    let onSelect: () -> Void
    let onFavorite: () -> Void
    let onDropCover: (URL) -> Void
    let menu: () -> [GameMenuItem]
    let perform: (GameAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activity) private var activity
    @State private var tilt: CGSize = .zero
    @State private var hovering = false

    // Not installed is black and white, until selected
    var inColor: Bool { game.installed || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            Text(game.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(activity.download(for: game)?.cardStatus ?? game.status())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            GameMenuContent(items: menu(), perform: perform)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"), onFavorite)
    }

    private var cover: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        return CoverView(game: game, override: override, gray: !inColor)
            .overlay {
                // A download brings the color back from the bottom up
                if !isSelected, let reveal = activity.reveal(for: game) {
                    RevealCover(game: game, override: override, progress: reveal)
                }
            }
            .aspectRatio(game.coverShape.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 0.5)
            }
            .overlay(alignment: .topLeading) {
                FavoriteStar(isOn: isFavorite, visible: isFavorite || hovering || isSelected, action: onFavorite)
            }
            .rotation3DEffect(.degrees(motion.tilts ? tilt.width : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(motion.tilts ? tilt.height : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .scaleEffect(motion.tilts && hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 10 : 4, y: hovering ? 6 : 2)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovering = true
                    guard motion.tilts else { return }
                    // Leans toward the pointer, at most 6 degrees
                    withAnimation(.interactiveSpring) {
                        tilt = CGSize(width: (point.x / 160 - 0.5) * 12, height: -(point.y / 240 - 0.5) * 12)
                    }
                case .ended:
                    hovering = false
                    withAnimation(motion.tilts ? .spring : nil) { tilt = .zero }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let image = urls.first(where: { NSImage(contentsOf: $0) != nil }) else { return false }
                onDropCover(image)
                return true
            }
    }
}

struct FavoriteStar: View {
    let isOn: Bool
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.yellow : Color.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .opacity(visible ? 1 : 0)
        .accessibilityLabel(isOn ? Text("Remove from Favorites") : Text("Add to Favorites"))
        .help(isOn ? Text("Remove from Favorites") : Text("Add to Favorites"))
    }
}
