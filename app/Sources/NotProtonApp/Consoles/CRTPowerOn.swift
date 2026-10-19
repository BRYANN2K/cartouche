import AppKit
import RetroArchKit
import SwiftUI

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
