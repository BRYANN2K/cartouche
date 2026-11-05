// Real one-color marks for the stores and consoles the library names, kept as template vectors
// in Brand.xcassets. A platform with no free mark shows its short name instead.

import AppKit
import RetroArchKit
import SwiftUI

enum PlatformMark: String, Sendable {
    case steam, epic, gog, amazon, ea, ubisoft
    case playstation, playstation2, psp, sega, atari, xbox

    var assetName: String { "mark-\(rawValue)" }

    static func source(_ source: GameSource) -> PlatformMark? {
        switch source {
        case .steam: .steam
        case .epic: .epic
        case .gog: .gog
        case .amazon: .amazon
        case .ea: .ea
        case .ubisoft: .ubisoft
        default: nil
        }
    }

    static func console(_ id: String) -> PlatformMark? {
        switch id {
        case "ps1": .playstation
        case "ps2": .playstation2
        case "psp": .psp
        case "genesis", "mastersystem", "gamegear": .sega
        case "atari2600": .atari
        case "xbox": .xbox
        default: nil
        }
    }
}

@MainActor
enum PlatformMarkImage {
    private static var cache: [PlatformMark: NSImage?] = [:]

    static func image(_ mark: PlatformMark) -> NSImage? {
        if let hit = cache[mark] { return hit }
        let found = Bundle.module.image(forResource: mark.assetName)
        cache[mark] = found
        return found
    }
}

struct PlatformMarkView: View {
    let mark: PlatformMark
    var size: CGFloat = 16
    var fallback: String = "gamecontroller"

    var body: some View {
        if let image = PlatformMarkImage.image(mark) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallback)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// A console's own mark where a free one exists, otherwise its shape glyph
struct ConsoleMarkView: View {
    let id: String
    var size: CGFloat = 16

    var body: some View {
        if let mark = PlatformMark.console(id) {
            PlatformMarkView(mark: mark, size: size)
        } else {
            ConsoleGlyphView(glyph: ConsoleCatalog.console(id)?.glyph ?? .cartridge)
        }
    }
}

// The mark a store or console wears in the sidebar and the + menu
enum PlatformBadge: Equatable, Sendable {
    case mark(PlatformMark)
    case text(String)

    // Short names, never an imitation of a logo. Switch is text by decision: trademark.
    private static let textMarks = [
        "nes": "NES", "snes": "SNES", "n64": "N64", "gb": "GB", "gbc": "GBC", "gba": "GBA", "nds": "DS",
        "gamecube": "GC", "wii": "Wii", "3ds": "3DS", "switch": "NSW", "pce": "PCE",
    ]

    static func source(_ source: GameSource) -> PlatformBadge? {
        PlatformMark.source(source).map(Self.mark)
    }

    static func console(_ id: String) -> PlatformBadge {
        if let mark = PlatformMark.console(id) { return .mark(mark) }
        return .text(textMarks[id] ?? String(id.prefix(3)).uppercased())
    }
}

struct BrandMark: View {
    let badge: PlatformBadge
    var size: CGFloat = 20

    var body: some View {
        switch badge {
        case .mark(let mark):
            PlatformMarkView(mark: mark, size: size * 0.86)
                .frame(width: size, height: size)
                .foregroundStyle(Color.primary)
        case .text(let text):
            let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            Text(verbatim: text)
                .font(.system(size: size * (text.count >= 4 ? 0.3 : text.count == 3 ? 0.335 : 0.38), weight: .bold))
                .tracking(size * -0.007)
                .lineLimit(1)
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(Glass.fill2, in: shape)
                .overlay { shape.strokeBorder(Glass.edge, lineWidth: 0.5) }
                .accessibilityHidden(true)
        }
    }
}
