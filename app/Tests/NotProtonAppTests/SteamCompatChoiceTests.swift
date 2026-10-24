import Foundation
import Testing

@testable import NotProtonApp

// Cartouche asks Steam for a game's tool through a request file the dylib applies
// (compatcheck covers that side), and reads Steam's choice back from config.vdf.
// A fixture Steam folder and a scratch data folder only.
@Suite("Setup written to Steam and read back")
@MainActor
struct SteamCompatChoiceTests {

    static let release = GameSetupTests.release
    static let fexBuild = GameSetupTests.fexBuild

    // Pairs for 26.3 with D3DMetal and the 41073 FEX build without it
    static func pairs(_ work: URL) throws -> [BackendTool] {
        let runners = work.appending(path: "runners")
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: release.id, runners: runners)
                .appending(path: "lib64/apple_gptk/external/D3DMetal.framework"),
            withIntermediateDirectories: true)
        let tools = RunnerRegistry.tools(for: [release.build!, fexBuild.build!])
        return CompatToolList.backendTools(for: tools, runners: runners)
    }

    static let availability = BackendAvailability(d3dMetalRunners: [release.id])

    func config(_ fixture: SteamFixture, _ mappings: [Int: String]) throws {
        let entries = mappings.sorted { $0.key < $1.key }.map {
            "\t\t\t\t\t\"\($0.key)\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"\($0.value)\"\n\t\t\t\t\t\t\"config\"\t\t\"\"\n\t\t\t\t\t\t\"priority\"\t\t\"250\"\n\t\t\t\t\t}\n"
        }.joined()
        try fixture.write("config/config.vdf", """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"CompatToolMapping"
        \t\t\t\t{
        \t\t\t\t\t"0"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"proton_9"
        \t\t\t\t\t}
        \(entries)\t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """)
    }

    @Test("A request names the game and the tool, a later one replaces it, an empty tool clears it, other tools are refused")
    func requestFile() throws {
        let work = try scratchDirectory("compat-requests")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "compat-requests")
        try SteamCompatChoice.request(appID: 1_245_620, tool: "cartouche-proton-26.3-dxmt", file: file)
        try SteamCompatChoice.request(appID: 730, tool: "cartouche-proton-26.3-dxvk", file: file)
        try SteamCompatChoice.request(appID: 1_245_620, tool: "cartouche-proton-26.3-d3dmetal", file: file)
        try SteamCompatChoice.request(appID: 413_150, tool: nil, file: file)
        try SteamCompatChoice.request(appID: 570, tool: "proton_9", file: file)
        try SteamCompatChoice.request(appID: 0, tool: "cartouche-proton-26.3-dxmt", file: file)
        try SteamCompatChoice.request(appID: 0, tool: nil, file: file)
        #expect(try String(contentsOf: file, encoding: .utf8)
            == "0\tcartouche-proton-26.3-dxmt\n730\tcartouche-proton-26.3-dxvk\n413150\t\n1245620\tcartouche-proton-26.3-d3dmetal\n",
                "app 0, Steam's default for other Windows games, is set but never cleared")
        #expect(SteamCompatChoice.pending(file: file)[413_150] == "")
        #expect(Set(SteamCompatChoice.asked(file: file).keys) == [0, 730, 413_150, 1_245_620])
        #expect(SupportPaths.compatRequests.lastPathComponent == (try IdentityTests.headerDefine("CARTOUCHE_COMPAT_REQUESTS")))
        let compat = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/feats/compat.c"), encoding: .utf8)
        #expect(compat.contains("CARTOUCHE_SUPPORT_DIR \"/\" CARTOUCHE_COMPAT_REQUESTS"))
    }

    @Test("Steam's per-game choices are read from config.vdf, without the global default")
    func readsConfig() throws {
        let fixture = try SteamFixture("compat-config")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try config(fixture, [1_245_620: "cartouche-proton-26.3-d3dmetal", 730: "proton_9"])
        let read = SteamCompatChoice.mappings(config: fixture.steam.appending(path: "config/config.vdf"))
        #expect(read == [1_245_620: "cartouche-proton-26.3-d3dmetal", 730: "proton_9"])
        #expect(SteamCompatChoice.mappings(config: fixture.steam.appending(path: "config/none.vdf")).isEmpty)
    }

    @Test("Every pair read back from Steam resolves to a setup that maps to the same pair")
    func bothDirections() throws {
        let work = try scratchDirectory("compat-both")
        defer { try? FileManager.default.removeItem(at: work) }
        let pairs = try Self.pairs(work)
        #expect(pairs.count == 10)
        for pair in pairs {
            let choice = try #require(GameSetupApplier.choice(fromTool: pair.name, in: pairs, runners: [Self.release, Self.fexBuild]))
            let setup = GameSetupResolver.resolve(choice, runners: [Self.release, Self.fexBuild], availability: Self.availability).setup
            #expect(GameSetupApplier.tool(for: setup, in: pairs)?.name == pair.name)
        }
        #expect(GameSetupApplier.choice(fromTool: "proton_9", in: pairs, runners: [Self.release]) == nil)
    }

    @Test("Elden Ring set to 26.3 with D3DMetal in Cartouche asks Steam for that pair; Steam's later choice shows in Cartouche")
    func eldenRing() async throws {
        let fixture = try SteamFixture("compat-elden")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = ScratchDefaults()
        let model = libraryModel(fixture, defaults: defaults)
        await model.load()
        model.runners = [Self.release, Self.fexBuild]
        model.backendAvailability = Self.availability
        model.backendTools = try Self.pairs(fixture.root)

        model.setSetup(GameSetupChoice(runnerID: Self.release.id, graphics: .d3dmetal), for: "steam:1245620")
        let requests = fixture.support.appending(path: "compat-requests")
        #expect(try String(contentsOf: requests, encoding: .utf8) == "1245620\tcartouche-proton-26.3-d3dmetal\n")
        #expect(SupportPaths.Steam.cartoucheTools(in: fixture.root).isEmpty, "nothing written to Steam's own folders")

        // Before the dylib applied it, Steam's older choice does not undo Cartouche's
        try config(fixture, [1_245_620: "cartouche-proton-26.3-wined3d"])
        model.adoptSteamChoices(SteamCompatChoice.mappings(config: fixture.steam.appending(path: "config/config.vdf")))
        #expect(model.setup(for: "steam:1245620").graphics == .d3dmetal)

        // The dylib consumed the request, but Steam has not saved config.vdf since
        try FileManager.default.removeItem(at: requests)
        let vdf = fixture.steam.appending(path: "config/config.vdf")
        model.adoptSteamChoices(SteamCompatChoice.mappings(config: vdf), written: Date(timeIntervalSinceNow: -3600))
        #expect(model.setup(for: "steam:1245620").graphics == .d3dmetal)

        // The user then picks DXVK in Steam's Properties, and Steam saves it
        try config(fixture, [1_245_620: "cartouche-proton-26.3-dxvk"])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: vdf.path(percentEncoded: false))
        model.adoptSteamChoices(SteamCompatChoice.mappings(config: vdf), written: SteamCompatChoice.modified(config: vdf))
        #expect(model.setup(for: "steam:1245620").graphics == .dxvk)
        #expect(model.resolution(for: try #require(model.game("steam:1245620"))).setup.backend == .dxvk)
        #expect(!FileManager.default.fileExists(atPath: requests.path(percentEncoded: false)), "Steam's own choice is not sent back")
    }

    @Test("Settings > Compatibility's defaults become Steam's tool for every other Windows game")
    func defaultsReachSteam() async throws {
        let fixture = try SteamFixture("compat-defaults")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = ScratchDefaults()
        let model = libraryModel(fixture, defaults: defaults)
        await model.load()
        model.runners = [Self.release, Self.fexBuild]
        model.backendAvailability = Self.availability
        model.backendTools = try Self.pairs(fixture.root)
        SetupDefaults(runnerID: Self.release.id, graphics: .dxvk).save(defaults.defaults)
        model.tellSteamDefaults()
        #expect(SteamCompatChoice.pending(file: model.compatRequestsFile)[0] == "cartouche-proton-26.3-dxvk")
        // A game with no choice of its own shows what Steam now runs it with
        let elden = try #require(model.game("steam:1245620"))
        #expect(model.resolution(for: elden).setup.backend == .dxvk)
    }

    @Test("The game's variables reach the run script's setups folder, and leave with the Mac version")
    func environmentFile() throws {
        let work = try scratchDirectory("compat-env")
        defer { try? FileManager.default.removeItem(at: work) }
        let pairs = try Self.pairs(work)
        var setup = GameSetupResolver.resolve(GameSetupChoice(graphics: .dxmt, metalHUD: true, environment: ["DXMT_LOG_LEVEL": "info"]),
                                              runners: [Self.release], availability: Self.availability).setup
        let requests = work.appending(path: "compat-requests"), setups = work.appending(path: "setups")
        let outcome = try GameSetupApplier.apply(setup, appID: 1_245_620, tools: pairs, requests: requests, setups: setups)
        #expect(outcome.tool == "cartouche-proton-26.3-dxmt")
        #expect(try String(contentsOf: setups.appending(path: "1245620.env"), encoding: .utf8) == "DXMT_LOG_LEVEL=info\nMTL_HUD_ENABLED=1\n")
        let script = try String(contentsOf: IdentityTests.repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        #expect(script.contains("setup_env=\"$np_support/\(try IdentityTests.headerDefine("CARTOUCHE_SETUPS_DIR"))/$app_id.env\""))
        #expect(script.contains("np_backend_files=\"$np_support/\(try IdentityTests.headerDefine("CARTOUCHE_BACKENDS_DIR"))/$np_backend\""))

        setup.version = .mac
        try GameSetupApplier.apply(setup, appID: 1_245_620, tools: pairs, requests: requests, setups: setups)
        #expect(!FileManager.default.fileExists(atPath: setups.appending(path: "1245620.env").path(percentEncoded: false)))
        #expect(SteamCompatChoice.pending(file: requests)[1_245_620] == "")
    }
}
