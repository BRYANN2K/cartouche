// Real one-color marks for the stores and consoles the library names, kept as template vectors
// in Brand.xcassets. A platform with no free mark keeps its neutral console glyph.

import AppKit
import RetroArchKit
import SwiftUI

enum PlatformMark: String, Sendable {
    case steam, epic, gog, amazon
    case playstation, playstation2, psp, sega, atari

    var assetName: String { "mark-\(rawValue)" }

    static func source(_ source: GameSource) -> PlatformMark? {
        switch source {
        case .steam: .steam
        case .epic: .epic
        case .gog: .gog
        case .amazon: .amazon
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
