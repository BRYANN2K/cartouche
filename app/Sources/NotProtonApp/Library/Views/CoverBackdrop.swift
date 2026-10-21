// The mockup's .backdrop: the selected game's art, blurred and dimmed, fills the window behind
// the glass so every surface picks up its color. Blurred once per picture, then cached.

import SwiftUI

struct CoverBackdrop: View {
    let game: Game?
    var override: URL?

    @Environment(\.covers) private var covers
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown: Shown?

    struct Shown: Equatable {
        let key: String
        let image: NSImage
    }

    private var key: String { "\(game?.id ?? "")|\(override?.path ?? "")" }

    var body: some View {
        let dark = colorScheme == .dark
        Glass.window
            .overlay {
                if !reduceTransparency, let shown {
                    Image(nsImage: shown.image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .colorMultiply(Color(white: dark ? 0.5 : 1))
                        .brightness(dark ? 0 : 0.2)
                        .opacity(dark ? 0.9 : 0.28)
                        .padding(-80)
                        .id(shown.key)
                        .transition(.opacity)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: key) {
                let next = await load()
                guard next?.key != shown?.key else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { shown = next }
            }
    }

    private func load() async -> Shown? {
        guard let game else { return nil }
        let key = key
        for kind in [ArtKind.hero, .cover] {
            // art() can end in iconmaker, a process wait: like CoverLoader, it stays off the main actor.
            let art = await Task.detached {
                await covers.art(for: game, kind: kind, override: kind == .cover ? override : nil)
            }.value
            if case .image(let url) = art,
               let blurred = await Task.detached(priority: .utility, operation: { CoverImages.backdrop(url) }).value {
                return Shown(key: key, image: blurred)
            }
        }
        return nil
    }
}
