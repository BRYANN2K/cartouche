import CartoucheIdentity
import Foundation
import Testing

@testable import NotProtonApp

// The text Cartouche writes for Wine, Steam, the in-game library and the release pipeline,
// rendered from fixed inputs and compared byte for byte with Goldens/ (see Golden.swift).
@Suite("Goldens")
@MainActor
struct GoldenTests {

    // MARK: Installer game launch script

    @Test("An installer game's launch script, per graphics backend")
    func launchScripts() throws {
        let work = try scratchDirectory("golden-launch")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let backends = work.appending(path: "backends")
        let wine = try #require(InstallRunners.wine(for: InstallerSetupTests.freeWine("wine-crossover-26.3.0-1", in: runners),
                                                    runners: runners))
        _ = try GameSetupTests.toolkit(in: runners)
        try InstallerSetupTests.dxmt(in: backends)
        let game = work.appending(path: "installs/Hollow Pines")
        let exe = game.appending(path: "drive_c/Games/Hollow Pines/HollowPines.exe")
        let cases: [(String, GraphicsBackend?, [String: String])] = [
            ("default", nil, [:]),
            ("dxmt", .dxmt, ["DXMT_LOG_LEVEL": "none", "GAME_FLAG": "it's quoted"]),
            ("d3dmetal", .d3dmetal, [:]),
        ]
        for (name, backend, environment) in cases {
            let script = GameLauncher.script(exe: exe, prefix: game.appending(path: "pfx"), wine: wine, backend: backend,
                                             environment: environment, backends: backends, runners: runners)
            try Golden.check(Golden.scrub(script, scratch: work), "launch/\(name).sh")
        }
    }

    // MARK: Steam compatibility tools

    @Test("The tools list Steam is offered for every pinned CrossOver build, with and without FEX")
    func toolLists() throws {
        for fex in [true, false] {
            let tools = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: fex)
            try Golden.check(CompatToolList.contents(tools), "steam-tools/tools-crossover\(fex ? "" : "-nofex").tsv")
        }
    }

    @Test("tools and backend-tools for CrossOver clones and a Cartouche Wine build")
    func toolFiles() throws {
        let work = try scratchDirectory("golden-tools")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = try SteamToolPairTests().runnersFolder(work)
        let wine = runners.appending(path: "wine-crossover-26.3.0-1")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        let receipt = WineRunnerInstaller.Receipt(id: "wine-crossover-26.3.0-1", archiveSHA256: "aa", files: [:], loader: "bin/wine")
        try JSONEncoder().encode(receipt).write(to: wine.appending(path: WineRunnerInstaller.receiptName))
        let file = work.appending(path: "tools")
        // The fixture manifest, not the app's: its Wine pins move with every runner release
        let manifest = try RunnerManifest.read(Data(contentsOf: Golden.folder.appending(path: "inputs/runners.json")))
        try CompatToolList.sync(runners: runners, bridge: work.appending(path: "bridge"), file: file,
                                compatTools: work.appending(path: "compatibilitytools.d"), fexAvailable: true, manifest: manifest,
                                backends: work.appending(path: "backends"))
        try Golden.check(String(contentsOf: file, encoding: .utf8), "steam-tools/tools.tsv")
        try Golden.check(String(contentsOf: work.appending(path: CARTOUCHE_BACKEND_TOOL_LIST), encoding: .utf8),
                         "steam-tools/backend-tools.tsv")
    }

    // MARK: Runner manifest

    @Test("A runner manifest reads into builds and writes back the same fields")
    func runnerManifest() throws {
        let data = try Data(contentsOf: Golden.folder.appending(path: "inputs/runners.json"))
        let manifest = try RunnerManifest.read(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Golden.check(String(decoding: try encoder.encode(manifest), as: UTF8.self) + "\n", "runners/manifest.json")

        var lines = ["format \(manifest.format) revision \(manifest.revision)"]
        for build in manifest.builds {
            lines.append([build.id, build.origin.rawValue, build.title, build.archiveName,
                          "flavors=\(build.cpuFlavors.map(\.rawValue).joined(separator: ","))",
                          "pinned=\(build.isPinned)", "pending=\(build.isPending)"].joined(separator: "\t"))
        }
        try Golden.check(lines.joined(separator: "\n") + "\n", "runners/builds.tsv")

        let invalid = try Data(contentsOf: Golden.folder.appending(path: "inputs/runners-invalid.json"))
        #expect(throws: ManifestInvalid.self) { try RunnerManifest.read(invalid) }
        let problems = try JSONDecoder().decode(RunnerManifest.self, from: invalid).problems()
        try Golden.check(problems.joined(separator: "\n") + "\n", "runners/problems.txt")
    }

    // MARK: Wine registry

    @Test("The registry writes a store or a game's settings make in a prefix")
    func registryWrites() throws {
        let ea = EARegistry.writes(exe: #"C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe"#)
        try Golden.check(ea.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n", "registry/ea-reg-add.tsv")
        try Golden.check(KeyboardOptions().registryFile, "registry/keyboard-default.reg")
        let on = KeyboardOptions(commandAsControl: true, optionAsAlt: true, keepMouseInside: false, preciseScrolling: false)
        try Golden.check(on.registryFile, "registry/keyboard-changed.reg")
        try Golden.check(["1", "0"].map { AdvancedPrefixSettings.retinaArguments($0).joined(separator: "\t") }
            .joined(separator: "\n") + "\n", "registry/retina-reg-add.tsv")
    }

    // MARK: What's New

    @Test("The What's New catalog, each page in English and French")
    func whatsNew() throws {
        defer { WhatsNewText.use(language: "en") }
        for language in ["en", "fr"] {
            WhatsNewText.use(language: language)
            var lines: [String] = []
            for release in WhatsNewCatalog.bundled {
                lines.append("# \(release.version)")
                for page in release.pages {
                    let line = WhatsNewText.string(page.line, page.shortcut ?? "")
                    lines += ["", "## \(page.id) image=\(page.image)\(page.isSoon ? " soon" : "")",
                              "title: \(WhatsNewText.string(page.title))", "line: \(line)",
                              "alt: \(WhatsNewText.string(page.alt))"]
                }
            }
            try Golden.check(lines.joined(separator: "\n") + "\n", "whats-new/catalog.\(language).txt")
        }
    }

    // MARK: Release notes

    @Test("CHANGELOG sections turn into release notes and site entries")
    func releaseNotes() throws {
        let changelog = Golden.folder.appending(path: "inputs/CHANGELOG.md").path(percentEncoded: false)
        for version in ["0.3.0", "0.2.1", "0.2.0-beta2"] {
            try Golden.check(try Self.release(["notes", version, "--changelog", changelog]), "release-notes/notes-\(version).md")
            try Golden.check(try Self.release(["site-entry", version, "--title", "Cartouche \(version)", "--changelog", changelog]),
                             "release-notes/site-entry-\(version).md")
        }
        try Golden.check(try Self.release(["meta", "v0.3.0", "--changelog", changelog,
                                           "--header", Golden.folder.appending(path: "inputs/version.h").path(percentEncoded: false),
                                           "--published", "v0.2.1 v0.2.0-beta2"]),
                         "release-notes/meta-v0.3.0.txt")
    }

    static func release(_ arguments: [String]) throws -> String {
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/env")
        python.arguments = ["python3", "-I", Golden.repo.appending(path: "packaging/release.py").path(percentEncoded: false)] + arguments
        let out = Pipe(), err = Pipe()
        python.standardOutput = out
        python.standardError = err
        try python.run()
        let text = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        if python.terminationStatus != 0 {
            Issue.record(Comment(rawValue: "release.py \(arguments.joined(separator: " ")): " + String(decoding: problem, as: UTF8.self)))
        }
        return String(decoding: text, as: UTF8.self)
    }

    // MARK: Shared memory blocks

    @Test("The control and metrics blocks keep the layout the library inside the game reads")
    func sharedBlocks() throws {
        func at<T>(_ path: PartialKeyPath<T>) -> String { MemoryLayout<T>.offset(of: path).map(String.init) ?? "?" }
        let control: [(String, PartialKeyPath<FGControlBlock>)] = [
            ("magic", \.magic), ("version", \.version), ("size", \.size), ("pid", \.pid), ("sequence", \.sequence),
            ("hud_level", \.hud_level), ("hud_corner", \.hud_corner), ("hud_scale", \.hud_scale), ("menu_open", \.menu_open),
            ("reduce_motion", \.reduce_motion), ("battery_percent", \.battery_percent), ("gpu_watts", \.gpu_watts),
            ("warning", \.warning), ("hotkey", \.hotkey), ("safe_top", \.safe_top), ("screen_height", \.screen_height),
            ("language", \.language),
        ]
        let metrics: [(String, PartialKeyPath<FGMetricsBlock>)] = [
            ("magic", \.magic), ("version", \.version), ("size", \.size), ("pid", \.pid), ("sequence", \.sequence),
            ("seconds", \.seconds), ("updated_ns", \.updated_ns), ("presented_fps", \.presented_fps), ("real_fps", \.real_fps),
            ("frame_ms", \.frame_ms), ("low1_fps", \.low1_fps), ("added_latency_ms", \.added_latency_ms),
            ("cpu_percent", \.cpu_percent), ("gpu_percent", \.gpu_percent), ("ram_bytes", \.ram_bytes),
            ("thermal", \.thermal), ("upscale", \.upscale), ("upscale_out_width", \.upscale_out_width),
            ("upscale_out_height", \.upscale_out_height), ("framegen", \.framegen), ("framegen_factor", \.framegen_factor),
            ("framegen_ane", \.framegen_ane), ("frame_count", \.frame_count), ("frame_ms_ring", \.frame_ms_ring),
        ]
        var lines = [String(format: "control name=%@ magic=0x%08x version=%u size=%u struct=%d", FG_CONTROL_NAME,
                            FG_CONTROL_MAGIC, FG_CONTROL_VERSION, FG_CONTROL_SIZE, MemoryLayout<FGControlBlock>.size)]
        lines += control.map { "  \($0.0) @\(at($0.1))" }
        lines.append(String(format: "metrics name=%@ magic=0x%08x version=%u size=%u frames=%u struct=%d", FG_METRICS_NAME,
                            FG_METRICS_MAGIC, FG_METRICS_VERSION, FG_METRICS_SIZE, FG_METRICS_FRAMES,
                            MemoryLayout<FGMetricsBlock>.size))
        lines += metrics.map { "  \($0.0) @\(at($0.1))" }

        // What the app writes for one fixed HUD state, as the library reads it
        let writer = try #require(ControlBlockWriter(pid: Int32.random(in: 900_000...990_000)))
        defer { writer.remove() }
        writer.write(HUDControl(level: .mini, corner: .bottomRight, scale: 125, menuOpen: true, reduceMotion: true, battery: 82,
                                gpuWatts: 14.5, warning: "Mac surchargé", hotkey: "⌥C", safeTop: 37, screenHeight: 1117,
                                language: "fr"))
        var block = writer.read()
        block.pid = 0
        let bytes = withUnsafeBytes(of: &block) { Array($0.prefix(216)) }
        lines.append("written (pid zeroed):")
        for row in stride(from: 0, to: bytes.count, by: 24) {
            lines.append("  " + bytes[row..<min(row + 24, bytes.count)].map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        try Golden.check(lines.joined(separator: "\n") + "\n", "overlay/shared-blocks.txt")
    }
}
