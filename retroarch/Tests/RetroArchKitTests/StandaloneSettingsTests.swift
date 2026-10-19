import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import RetroArchKit

// P16, scenario "Dolphin installed": Settings > Consoles lists Dolphin with
// its version, and GameCube and Wii offer it. Dolphin here is a fake app in
// the scratch folder's Applications.
@MainActor
@Suite("Settings > Consoles with standalone emulators", .serialized)
struct StandaloneSettingsTests {

    @Test func dolphinIsListedWithItsVersionAndOfferedForGameCubeAndWii() async throws {
        let work = try scratchFolder("settings-emulators")
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appending(path: "Applications", directoryHint: .isDirectory)
        try FakeEmulators.app("Dolphin", in: applications, bundleID: "org.dolphin-emu.dolphin", version: "2509")
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(["gamecube", "wii"]).write(to: paths.consoles)
        let model = ConsolesSettingsModel(
            paths: paths, includedApp: work.appending(path: "RetroArch.app"), cores: CoreManager(paths: paths),
            official: OfficialRelease(paths: paths), probe: { _ in nil })
        let emulators = EmulatorShelf(paths: paths, detector: EmulatorDetector(folders: [applications]))
        await model.refresh()
        await emulators.refresh()

        for id in ["gamecube", "wii"] {
            let console = try #require(ConsoleCatalog.console(id))
            #expect(emulators.options(for: console).map(\.title) == ["RetroArch (Dolphin)", "Dolphin 2509"])
            #expect(emulators.selected(for: console) == "dolphin")
        }
        let view = ConsolesSettingsView(model: model, emulators: emulators, chooseApp: { nil })
        let texts = try await renderedTexts(view)
        print("evidence: Settings > Consoles reads \(texts)")
        #expect(texts.contains("Dolphin 2509"))
        #expect(texts.contains { $0.contains("GameCube") && $0.contains("Wii") })
        #expect(texts.contains("GameCube plays in"))
        #expect(texts.contains("Wii plays in"))
        #expect(texts.filter { $0 == "Dolphin 2509" }.count >= 3, "the list and both pickers show Dolphin 2509")

        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
            for scheme in [ColorScheme.light, .dark] {
                let png = try snapshot(view, scheme: scheme)
                try png.write(to: URL(fileURLWithPath: folder)
                    .appending(path: "p16-settings-dolphin-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func noEmulatorSaysNoneFound() async throws {
        let work = try scratchFolder("settings-none")
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = RetroArchPaths(root: work.appending(path: "cartouche"))
        let model = ConsolesSettingsModel(
            paths: paths, includedApp: work.appending(path: "RetroArch.app"), cores: CoreManager(paths: paths),
            official: OfficialRelease(paths: paths), probe: { _ in nil })
        let emulators = EmulatorShelf(paths: paths, detector: EmulatorDetector(folders: [work.appending(path: "Applications")]))
        await emulators.refresh()
        let texts = try await renderedTexts(ConsolesSettingsView(model: model, emulators: emulators, chooseApp: { nil }))
        #expect(texts.contains("None found in Applications."))
        #expect(texts.contains("Other Emulators") || texts.contains("OTHER EMULATORS"))
    }

    private func host(_ view: some View, scheme: ColorScheme = .light) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: 560, height: 760))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 760)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    // What the pane draws, read back with text recognition, as a person sees it
    private func renderedTexts(_ view: some View) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(150))
        let png = try snapshot(view, scheme: .light)
        let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func snapshot(_ view: some View, scheme: ColorScheme) throws -> Data {
        let hosting = host(view, scheme: scheme)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
