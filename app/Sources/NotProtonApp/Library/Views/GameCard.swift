import SwiftUI

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
    var antiCheatBlocked = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.activity) private var activity
    @State private var hovering = false

    var inColor: Bool { game.installed || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            Text(game.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 9)
            status
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.top, 1)
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

    @ViewBuilder
    private var status: some View {
        if activity.playing?.id == game.id {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(activity.download(for: game)?.cardStatus ?? game.status())
            }
            .foregroundStyle(Color.green)
        } else {
            let download = activity.download(for: game)
            Text(download?.cardStatus ?? (antiCheatBlocked ? String(localized: "Anti-cheat blocks Linux") : game.status()))
                .foregroundStyle(download?.isFailed == true || (download == nil && antiCheatBlocked) ? Color.red : Glass.label2)
        }
    }

    private var cover: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let dark = colorScheme == .dark
        let download = activity.download(for: game)
        return CoverView(game: game, override: override)
            .saturation(inColor ? 1 : 0)
            .aspectRatio(game.coverShape.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let download {
                    RevealCover(game: game, override: override,
                                progress: .init(fraction: download.fraction,
                                                animating: !download.isPaused && !download.isFailed))
                }
            }
            .clipShape(shape)
            .overlay { CoverEdge(radius: 12) }
            .shadow(color: .black.opacity(hovering ? (dark ? 0.42 : 0.18) : (dark ? 0.32 : 0.12)),
                    radius: hovering ? 13 : 9, y: hovering ? 9 : 6)
            .background {
                // Selection: a thin accent ring held off the cover, the way Photos marks a picked tile
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .padding(-4)
                }
            }
            .overlay {
                if activity.playing?.id == game.id {
                    PlayingRing(reduceMotion: reduceMotion)
                }
            }
            .overlay(alignment: .topTrailing) {
                if download?.isFailed == true {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                FavoriteStar(isOn: isFavorite, visible: isFavorite || hovering, action: onFavorite)
            }
            .scaleEffect(motion.tilts && hovering ? 1.03 : 1)
            .animation(motion.tilts ? .spring(duration: 0.3, bounce: 0) : .easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .dropDestination(for: URL.self) { urls, _ in
                guard let image = urls.first(where: { NSImage(contentsOf: $0) != nil }) else { return false }
                onDropCover(image)
                return true
            }
    }
}

// The cover's edge: a hairline inside the rounded rectangle so the art never bleeds into the backdrop
struct CoverEdge: View {
    let radius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = colorScheme == .dark
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(dark ? Color.white.opacity(reduceTransparency ? 0.2 : 0.12) : Color.black.opacity(0.1),
                          lineWidth: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// A playing game's cover: a green ring that breathes, still under Reduce Motion
private struct PlayingRing: View {
    let reduceMotion: Bool
    @State private var low = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.green, lineWidth: 2)
            .shadow(color: .green.opacity(low ? 0.25 : 0.45), radius: low ? 5 : 13)
            .padding(-2)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { low = true }
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.yellow : Color.white)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color(white: 0.08, opacity: 0.45), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(FavoriteStarStyle())
        .padding(8)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        .accessibilityLabel(isOn ? Text("Remove from Favorites") : Text("Add to Favorites"))
        .help(isOn ? Text("Remove from Favorites") : Text("Add to Favorites"))
    }
}

private struct FavoriteStarStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
