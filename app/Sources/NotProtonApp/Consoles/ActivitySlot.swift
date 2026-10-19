import AppKit
import RetroArchKit
import SwiftUI

// The sidebar's activity slot while a console game runs: what plays, and Quit.
// P7 adds downloads and installs to the same slot.
struct ActivitySlot: View {
    let center: ConsoleCenter
    let model: LibraryModel

    var body: some View {
        if let playing = center.playing, let game = center.game(playing.gameID) {
            HStack(spacing: 10) {
                CoverView(game: ConsoleCenter.libraryGame(game))
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playing.phase == .starting ? String(localized: "Starting…") : String(localized: "Playing"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: game.name).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Quit") { Task { await center.quit() } }
                    .controlSize(.small)
                    .disabled(playing.phase == .starting)
                    .help(Text("Quit the game. RetroArch saves where you are first."))
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection = .source(.console(game.console))
                model.select(game.id)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(game.name), playing"))
        }
    }
}

// The CRT power-on over the window when a console game starts: a thin bright
// line opens into the game's picture, then RetroArch takes the screen. Not
// shown with Reduce Motion.
struct CRTPowerOn: View {
    let powerOn: PowerOn
    let done: () -> Void
    @State private var open = false
    @State private var fade = false

    static let duration = 1.5

    var body: some View {
        ZStack {
            Color.black
            Group {
                if let picture = powerOn.picture, let image = NSImage(contentsOf: picture) {
                    Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.85)
                }
            }
            .overlay { LookOverlay(look: .crt) }
            .scaleEffect(x: open ? 1 : 0.6, y: open ? 1 : 0.004)
            .brightness(open ? 0 : 0.8)
            .clipped()
        }
        .opacity(fade ? 0 : 1)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)) { open = true }
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeIn(duration: 0.4)) { fade = true }
            try? await Task.sleep(for: .seconds(0.4))
            done()
        }
    }
}
