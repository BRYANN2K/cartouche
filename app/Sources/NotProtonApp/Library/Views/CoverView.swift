import AppKit
import CoreImage
import SwiftUI

private struct CoverStoreKey: EnvironmentKey {
    static let defaultValue = CoverStore()
}

extension EnvironmentValues {
    var covers: CoverStore {
        get { self[CoverStoreKey.self] }
        set { self[CoverStoreKey.self] = newValue }
    }
}

@MainActor
enum CoverImages {
    private static let cache = NSCache<NSString, NSImage>()

    // The black and white copy is made once per cover, so the grid never filters live
    static func image(_ url: URL, gray: Bool = false) -> NSImage? {
        let key = "\(gray ? "gray:" : "")\(url.path(percentEncoded: false))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        let result = gray ? (blackAndWhite(image) ?? image) : image
        cache.setObject(result, forKey: key)
        return result
    }

    static func blackAndWhite(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let rendered = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: rendered, size: image.size)
    }
}

// A cover or a hero picture. Never a broken image: anything unreadable is drawn.
struct CoverView: View {
    let game: Game
    var override: URL?
    var kind: ArtKind = .cover
    // Not installed and not selected
    var gray = false

    @Environment(\.covers) private var covers
    @State private var art: CoverArt?

    var body: some View {
        ZStack {
            // A console box, landscape or portrait, sits whole in its square
            if game.coverShape == .square && kind == .cover {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
            // What is on disk shows at once; only the CDN waits for the task
            switch art ?? covers.local(for: game, kind: kind, override: override) {
            case .image(let url):
                if let image = CoverImages.image(url, gray: gray) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: game.coverShape == .square && kind == .cover ? .fit : .fill)
                } else {
                    DrawnCover(game: game, compact: kind == .hero)
                }
            case .drawn:
                DrawnCover(game: game, compact: kind == .hero)
            case nil:
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: "\(game.id)|\(override?.path ?? "")|\(kind.rawValue)") {
            art = nil
            if covers.local(for: game, kind: kind, override: override) != nil { return }
            art = await covers.art(for: game, kind: kind, override: override)
        }
    }
}

// The game's name and its executable's icon on a plain background
struct DrawnCover: View {
    let game: Game
    var compact = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
            VStack(spacing: 10) {
                if let exe = game.executable, FileManager.default.fileExists(atPath: exe.path(percentEncoded: false)) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: exe.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                }
                Text(game.name)
                    .font(compact ? .title3.weight(.semibold) : .headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
            }
            .padding(12)
        }
    }
}
