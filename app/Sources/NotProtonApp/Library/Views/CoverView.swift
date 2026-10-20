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

enum CoverLoader {

    struct Loaded: @unchecked Sendable {
        var art: CoverArt
        var color: NSImage?
        var gray: NSImage?
        // The same CGImage every body pass, so the Metal texture cache hits
        var colorCG: CGImage?
    }

    static func load(_ game: Game, kind: ArtKind, override: URL?, covers: CoverStore, gray: Bool) async -> Loaded {
        await Task.detached { () -> Loaded in
            let art = await covers.art(for: game, kind: kind, override: override)
            guard case .image(let url) = art else { return Loaded(art: art) }
            var loaded = Loaded(art: art)
            loaded.color = CoverImages.image(url)
            loaded.gray = gray ? CoverImages.image(url, gray: true) : nil
            loaded.colorCG = loaded.color?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return loaded
        }.value
    }
}

enum CoverImages {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private static let context = CIContext()

    static func image(_ url: URL, gray: Bool = false) -> NSImage? {
        let key = "\(gray ? "gray:" : "")\(url.path(percentEncoded: false))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        let result = gray ? (blackAndWhite(image) ?? image) : image
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        cache.setObject(result, forKey: key, cost: pixels * 4)
        return result
    }

    static func blackAndWhite(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: rendered, size: image.size)
    }
}

// A cover or a hero picture. Never a broken image: anything unreadable is drawn.
struct CoverView: View {
    let game: Game
    var override: URL?
    var kind: ArtKind = .cover
    var gray = false

    @Environment(\.covers) private var covers
    @State private var loaded: CoverLoader.Loaded?

    var body: some View {
        ZStack {
            if game.coverShape == .square && kind == .cover {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
            switch loaded?.art {
            case .image:
                if let image = gray ? loaded?.gray ?? loaded?.color : loaded?.color {
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
        .task(id: "\(game.id)|\(override?.path ?? "")|\(kind.rawValue)|\(game.artwork?.absoluteString ?? "")|\(gray)") {
            loaded = nil
            loaded = await CoverLoader.load(game, kind: kind, override: override, covers: covers, gray: gray)
        }
    }
}

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
