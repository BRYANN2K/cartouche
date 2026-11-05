import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

// Cartouche follows the accent picked in System Settings; red is left to failures and destructive actions
@Suite("System accent")
@MainActor
struct AccentColorTests {

    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appending(path: path), encoding: .utf8)
    }

    @Test("The bundle names no accent colour, so macOS uses the player's")
    func bundle() throws {
        #expect(!FileManager.default.fileExists(atPath: Self.repo.appending(path: "app/Assets/App.xcassets/AccentColor.colorset").path(percentEncoded: false)))
        #expect(try !text("app/Info.plist").contains("NSAccentColorName"))
        #expect(try !text("Makefile").contains("--accent-color"))
    }

    @Test("No window root overrides the accent, and no fixed red stands in for it")
    func noOverride() throws {
        let glass = try text("app/Sources/NotProtonApp/Library/Views/Glass.swift")
        #expect(glass.contains("static let accentFill = Color.accentColor"))
        for path in ["app/Sources/NotProtonApp/App.swift", "app/Sources/NotProtonApp/Overlay/OverlayPanel.swift"] {
            let source = try text(path)
            #expect(!source.contains(".accentColor(") && !source.contains("cartoucheAccent"), "\(path)")
        }
        #expect(!glass.contains("0xD4 / 255"))
    }

    @Test("The in-game menu's destructive red stays its own, apart from the accent")
    func overlay() {
        #expect(NSColor(OS.red).usingColorSpace(.sRGB) != NSColor(OS.accent).usingColorSpace(.sRGB))
        let danger = NSColor(OS.danger).usingColorSpace(.sRGB)!
        #expect(danger.redComponent > danger.blueComponent && danger.redComponent > danger.greenComponent)
    }
}
