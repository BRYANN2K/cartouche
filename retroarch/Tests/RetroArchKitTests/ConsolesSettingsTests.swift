import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import RetroArchKit

// Settings > Consoles: the version picker, what each build can do, and the
// -L fallback for a build without MCP
@MainActor
@Suite("Settings > Consoles", .serialized)
struct ConsolesSettingsTests {

    final class Stage {
        let work: URL
        let paths: RetroArchPaths
        let server: FixtureServer
        let base: URL
        let argsLog: URL
        // The fixture image is pinned as the real one is; its unsigned app passes a stand-in signature check
        var pins = OfficialRelease.pins
        var signed = true

        init(official: Bool = false) async throws {
            work = try scratchFolder("settings")
            paths = RetroArchPaths(root: work.appending(path: "cartouche"))
            server = try FixtureServer()
            base = try await server.start()
            argsLog = work.appending(path: "official-args.txt")
            if official {
                let image = try officialImage()
                pins = ["1.22.2": ReleasePin(size: Int64(image.count), sha256: Self.sha256(image))]
                server.put("/stable/1.22.2/apple/osx/universal/RetroArch_Metal.dmg", image)
            }
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        deinit { server.stop() }

        func officialImage() throws -> Data {
            let folder = work.appending(path: "image", directoryHint: .isDirectory)
            let macos = folder.appending(path: "RetroArch.app/Contents/MacOS", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let script = macos.appending(path: "RetroArch")
            try """
            #!/bin/sh
            case "$1" in
            --version) echo "RetroArch - Frontend for libretro"; echo "Version: 1.22.2 Aug 1 2026"; exit 0 ;;
            --help) echo "Usage: retroarch [OPTIONS]... [FILE]"; echo "  -L, --libretro=FILE  Path to libretro implementation."; exit 0 ;;
            esac
            echo "$@" >> "\(argsLog.path)"
            trap 'exit 0' TERM
            while :; do sleep 1 & wait $!; done
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let image = work.appending(path: "RetroArch_Metal.dmg")
            let hdiutil = Process()
            hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hdiutil.arguments = ["create", "-quiet", "-srcfolder", folder.path, "-volname", "RetroArch", "-format", "UDZO", image.path]
            try hdiutil.run()
            hdiutil.waitUntilExit()
            return try Data(contentsOf: image)
        }

        // The included build: fake-retroarch, which has MCP
        var included: URL { Fixtures.fakeRetroArch }

        @MainActor func model() -> ConsolesSettingsModel {
            let source = CoreSource(cores: base.appending(path: "nightly/"), info: base.appending(path: "info.zip"))
            let session = URLSession(configuration: .ephemeral)
            return ConsolesSettingsModel(
                paths: paths, includedApp: included,
                cores: CoreManager(paths: paths, source: source, session: session),
                official: official(session))
        }

        func official(_ session: URLSession = URLSession(configuration: .ephemeral)) -> OfficialRelease {
            let signed = signed
            return OfficialRelease(paths: paths, base: base.appending(path: "stable/"), session: session,
                                   pins: pins, signed: { _ in signed })
        }
    }

    @Test func theIncludedBuildIsTheDefaultAndDoesEverything() async throws {
        let stage = try await Stage()
        let model = stage.model()
        #expect(model.choice == .included)
        await model.refresh()
        #expect(model.capabilities?.mcp == true)
        #expect(model.features.allSatisfy { $0.available && $0.note == nil })
        #expect(model.launcher?.launch().arguments().first == "--mcp-stdio")
    }

    @Test func anOfficialReleaseWithoutMCPLaunchesWithLAndSaysWhatItLacks() async throws {
        let stage = try await Stage(official: true)
        let model = stage.model()
        await model.select(.official(version: "1.22.2"))

        #expect(model.capabilities == RetroArchCapabilities(mcp: false, version: "1.22.2"))
        let continueFrom = try #require(model.features.first { $0.feature == .continueFrom })
        let coach = try #require(model.features.first { $0.feature == .coachMode })
        #expect(continueFrom.title == "Continue From" && continueFrom.note == "Needs the included RetroArch")
        #expect(coach.title == "Coach mode" && coach.note == "Needs the included RetroArch")

        let core = stage.work.appending(path: "snes9x_libretro.dylib")
        let rom = stage.work.appending(path: "Test Cart.sfc")
        let launcher = try #require(model.launcher)
        let session = RetroArchSession(launch: launcher.launch())
        try await session.start(core: core, content: rom)
        var logged = ""
        for _ in 0..<100 {
            logged = (try? String(contentsOf: stage.argsLog, encoding: .utf8)) ?? ""
            if !logged.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(logged.contains("-L \(core.path) \(rom.path)"))
        #expect(!logged.contains("--mcp-stdio"))
        #expect(try String(contentsOf: stage.paths.appendConfig, encoding: .utf8).contains("network_cmd_enable = \"true\""))
        #expect(await session.stop().way == .terminated)
    }

    @Test func theChoiceIsKept() async throws {
        let stage = try await Stage()
        let model = stage.model()
        await model.chooseOwnCopy(Fixtures.fakeRetroArch)
        #expect(stage.model().choice == .custom(path: Fixtures.fakeRetroArch.path(percentEncoded: false)))
        #expect(model.choices.contains(model.choice))
    }

    @Test func aBuildThatIsNotThereOffersNothing() async throws {
        let stage = try await Stage()
        let model = stage.model()
        await model.chooseOwnCopy(stage.work.appending(path: "Gone.app"))
        #expect(model.build == .notFound)
        #expect(model.launcher == nil)
        #expect(model.features.allSatisfy { !$0.available })
    }

    @Test func aFailedDownloadSaysSo() async throws {
        let stage = try await Stage()
        stage.server.fail("/stable/1.22.2/apple/osx/universal/RetroArch_Metal.dmg", with: 502)
        let model = stage.model()
        await model.select(.official(version: "1.22.2"))
        #expect(model.build == .failed("RetroArch download failed, try again later."))
        #expect(model.launcher == nil)
    }

    @Test func anImageThatIsNotThePinnedOneIsNotInstalled() async throws {
        let stage = try await Stage(official: true)
        let pin = try #require(stage.pins["1.22.2"])
        stage.pins["1.22.2"] = ReleasePin(size: pin.size, sha256: String(repeating: "0", count: 64))
        let model = stage.model()
        await model.select(.official(version: "1.22.2"))
        #expect(model.build == .failed("This RetroArch could not be verified, so it was not installed."))
        #expect(!stage.official().isInstalled("1.22.2"))
    }

    @Test func anAppWithoutLibretrosSignatureIsNotInstalled() async throws {
        let stage = try await Stage(official: true)
        stage.signed = false
        let model = stage.model()
        await model.select(.official(version: "1.22.2"))
        #expect(model.build == .failed("This RetroArch could not be verified, so it was not installed."))
        #expect(!stage.official().isInstalled("1.22.2"))
    }

    @Test func aVersionWithoutAPinIsRefusedBeforeDownloading() async throws {
        let stage = try await Stage(official: true)
        stage.pins = [:]
        await #expect(throws: OfficialReleaseError.unverified) { try await stage.official().install("1.22.2") }
        #expect(stage.server.requests.isEmpty)
    }

    @Test func everyOfferedVersionIsPinned() {
        #expect(!OfficialRelease.versions.isEmpty)
        for version in OfficialRelease.versions {
            let pin = OfficialRelease.pins[version]
            #expect(pin.map { $0.size > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) } == true)
        }
    }

    // The real check: an unsigned bundle, and one signed ad hoc, are both refused
    @Test func theSignatureCheckRefusesAnythingButLibretrosDeveloperID() throws {
        let work = try scratchFolder("signature")
        let app = work.appending(path: "RetroArch.app", directoryHint: .isDirectory)
        let macos = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appending(path: "RetroArch"))
        #expect(!OfficialRelease.signedByLibretro(app))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-f", "-s", "-", app.path]
        try codesign.run()
        codesign.waitUntilExit()
        #expect(codesign.terminationStatus == 0)
        #expect(!OfficialRelease.signedByLibretro(app))
    }

    // The pane itself, drawn as the Settings window would and read back with
    // text recognition: the label, and a missing BIOS named with no way to
    // download one
    @Test func thePaneShowsNeedsTheIncludedRetroArch() async throws {
        let stage = try await Stage(official: true)
        stage.server.put("/nightly/swanstation_libretro.dylib.zip",
                         try zipFixture(["swanstation_libretro.dylib": fakeCore("1")], in: stage.work))
        stage.server.put("/info.zip", try zipFixture(
            ["swanstation_libretro.info": try Data(contentsOf: Fixtures.url("info/swanstation_libretro.info"))], in: stage.work))
        let model = stage.model()
        await model.select(.official(version: "1.22.2"))
        await model.add(ConsoleCatalog.console("ps1")!)

        let texts = try await renderedTexts(ConsolesSettingsView(model: model, chooseApp: { nil }))
        #expect(texts.contains("Needs the included RetroArch"))
        #expect(texts.contains("Continue From"))
        #expect(texts.contains("Coach mode"))
        #expect(texts.contains("PlayStation"))
        #expect(texts.contains("scph5501.bin is missing"))
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("bios") && $0.localizedCaseInsensitiveContains("download") })

        if let folder = ProcessInfo.processInfo.environment["CARTOUCHE_EVIDENCE_DIR"] {
            for scheme in [ColorScheme.light, .dark] {
                let png = try snapshot(ConsolesSettingsView(model: model, chooseApp: { nil }), scheme: scheme)
                try png.write(to: URL(fileURLWithPath: folder).appending(path: "p12-settings-consoles-\(scheme == .dark ? "dark" : "light").png"))
            }
        }

        await model.select(.included)
        let included = try await renderedTexts(ConsolesSettingsView(model: model, chooseApp: { nil }))
        #expect(!included.contains("Needs the included RetroArch"))
    }

    private func host(_ view: some View, scheme: ColorScheme = .light) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: 560, height: 420))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func renderedTexts(_ view: some View) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(100))
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
