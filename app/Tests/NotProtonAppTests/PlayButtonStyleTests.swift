import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NotProtonApp

@Suite("Play button, Apple TV style", .serialized)
@MainActor
struct PlayButtonStyleTests {

    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var color: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        var description: String { "(\(r), \(g), \(b))" }
    }

    private static func luminance(_ c: RGB) -> Double {
        func line(_ v: Int) -> Double {
            let v = Double(v) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * line(c.r) + 0.7152 * line(c.g) + 0.0722 * line(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // A square label: a shape fills with the foreground style, so its centre reads the label colour
    private struct Probe: View {
        var disabled = false
        var body: some View {
            Button {} label: { Rectangle().frame(width: 16, height: 16) }
                .buttonStyle(PlayCapsuleStyle())
                .disabled(disabled)
                .frame(width: 220)
                .padding(10)
                .background(Glass.window)
        }
    }

    // Fill at 30 pt from the left, label at the centre, in points
    private func read(dark: Bool, disabled: Bool = false) async throws -> (fill: RGB, label: RGB) {
        let size = CGSize(width: 240, height: 56)
        let host = NSHostingView(rootView: Probe(disabled: disabled)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await Task.sleep(for: .seconds(0.2))
        let rep = try #require(renderedBitmap(host))
        func at(_ x: CGFloat, _ y: CGFloat) throws -> RGB {
            let c = try #require(rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
            return RGB(r: Int(c.redComponent * 255 + 0.5), g: Int(c.greenComponent * 255 + 0.5), b: Int(c.blueComponent * 255 + 0.5))
        }
        let result = (fill: try at(40, 28), label: try at(120, 28))
        window.contentView = nil
        return result
    }

    @Test("Dark mode: a white fill under black text and icon")
    func dark() async throws {
        let (fill, label) = try await read(dark: true)
        #expect(fill.r >= 245 && fill.g >= 245 && fill.b >= 245, "fill \(fill)")
        #expect(label.r <= 10 && label.g <= 10 && label.b <= 10, "label \(label)")
    }

    @Test("Light mode: a black fill under white text and icon")
    func light() async throws {
        let (fill, label) = try await read(dark: false)
        #expect(fill.r <= 10 && fill.g <= 10 && fill.b <= 10, "fill \(fill)")
        #expect(label.r >= 245 && label.g >= 245 && label.b >= 245, "label \(label)")
    }

    @Test("Disabled, as while launching or offline, the label still reads on its fill")
    func disabled() async throws {
        for dark in [false, true] {
            let (fill, label) = try await read(dark: dark, disabled: true)
            #expect(Self.contrast(fill, label) >= 4.5, "dark \(dark): fill \(fill) label \(label)")
        }
    }

    @Test("Play keeps its own white or ink fill; the other filled buttons take the accent")
    func source() throws {
        let glass = try String(contentsOf: Self.repo.appending(path: "app/Sources/NotProtonApp/Library/Views/Glass.swift"), encoding: .utf8)
        let play = try #require(glass.range(of: "private struct PlayCapsuleBody"))
        let end = try #require(glass.range(of: "struct RoundFillStyle", range: play.upperBound..<glass.endIndex))
        let body = glass[play.lowerBound..<end.lowerBound]
        #expect(!body.contains("accentFill"))
        #expect(!body.contains("accentColor"))
        #expect(glass.contains("static let accentFill"))
        for name in ["SheetButtonBody", "BigCapsuleBody", "PillButtonStyle"] {
            let start = try #require(glass.range(of: name))
            #expect(glass[start.lowerBound...].prefix(900).contains("Glass.accentFill"), "\(name)")
        }
    }

    // The panel's play row in each state, beside the accent controls that keep their red
    private struct Gallery: View {
        @State private var on = true

        private func row<Primary: View>(_ primary: Primary, ring: Bool = false) -> some View {
            HStack(spacing: 8) {
                primary.couchRing(ring, radius: 18)
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(RoundFillStyle())
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    row(Button {} label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PlayCapsuleStyle()))
                    row(Button {} label: { Label("Install", systemImage: "arrow.down") }.buttonStyle(PlayCapsuleStyle()))
                    row(Button {} label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(PlayCapsuleStyle()), ring: true)
                    row(Button {} label: {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Launching…") }
                    }.buttonStyle(PlayCapsuleStyle()).disabled(true))
                    row(Button {} label: { Label("Install", systemImage: "arrow.down") }.buttonStyle(PlayCapsuleStyle()).disabled(true))
                    HStack(spacing: 8) {
                        Button("Stop") {}.buttonStyle(PlayCapsuleStyle(neutral: true))
                        Button("In-Game Menu") {}.buttonStyle(PlayCapsuleStyle(neutral: true)).fixedSize(horizontal: true, vertical: false)
                        Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(RoundFillStyle())
                    }
                }
                .padding(18)
                .frame(width: 340)
                .floatingPanel(liquid: false)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button("Add") {}.buttonStyle(.sheetProminent)
                        Button("Sign In") {}.buttonStyle(.pillProminent)
                    }
                    Button("Sign In with Epic…") {}.buttonStyle(BigCapsuleStyle())
                    Toggle("Toggle", isOn: $on).toggleStyle(.switch)
                    ProgressView(value: 0.6).progressViewStyle(.linear).frame(width: 200)
                    Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
                .padding(18)
                .frame(width: 260, alignment: .leading)
                .floatingPanel(liquid: false)
            }
            .padding(24)
            .frame(width: 680, height: 380, alignment: .topLeading)
            .background(Glass.window)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARTOUCHE_PLAY_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["CARTOUCHE_PLAY_SNAPSHOTS"] ?? "/tmp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let size = CGSize(width: 680, height: 380)
            let host = NSHostingView(rootView: Gallery().environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(0.6))
            let rep = try #require(renderedBitmap(host))
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "play-\(dark ? "dark" : "light").png"))
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
