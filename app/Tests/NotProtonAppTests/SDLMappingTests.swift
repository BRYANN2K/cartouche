import Foundation
import InstallerKit
import RetroArchKit
import Testing

@testable import NotProtonApp

// A game installed from a Windows installer, with a stand-in Wine that writes down
// how the launcher called it instead of running anything
struct LauncherFixture {
    let work: URL
    let folder: GameFolder
    let game: Game
    let files: ControlsFiles
    let out: URL

    init(_ label: String) throws {
        work = try scratchDirectory(label)
        let installs = work.appending(path: "installs")
        folder = GameFolder(root: installs.appending(path: "hades"))
        try FileManager.default.createDirectory(at: folder.prefix.appending(path: "drive_c/Games/Hades"), withIntermediateDirectories: true)
        out = work.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bin = work.appending(path: "wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let loader = bin.appending(path: "wine")
        try """
        #!/bin/sh
        if [ "$1 $2" = "reg import" ]; then
          cp "$WINEPREFIX/drive_c/cartouche-keyboard.reg" "$FAKE_OUT/imported.reg"
          printf "%s\\n" "reg import $3" >> "$FAKE_OUT/calls"
          exit 0
        fi
        env > "$FAKE_OUT/env"
        printf "%s\\n" "game $*" >> "$FAKE_OUT/calls"
        """.write(to: loader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        let wine = WineRunner(root: work.appending(path: "wine"), loader: loader, server: bin.appending(path: "wineserver"), dllPath: "")
        let exe = folder.prefix.appending(path: "drive_c/Games/Hades/Hades.exe")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        try GameLauncher.write(exe: exe, folder: folder, wine: wine)
        game = Game(id: "installer:hades", source: .installer, name: "Hades", installed: true, executable: exe)
        files = ControlsFiles(installs: installs, setups: work.appending(path: "setups"),
                              retroArch: RetroArchPaths(root: work.appending(path: "retroarch")))
    }

    // Runs the launcher as Steam's shortcut or the library would
    @discardableResult
    func launch() throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [folder.launcher.path(percentEncoded: false)]
        process.environment = ["PATH": "/usr/bin:/bin", "FAKE_OUT": out.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        let text = (try? String(contentsOf: out.appending(path: "env"), encoding: .utf8)) ?? ""
        var env: [String: String] = [:]
        var last: String?
        // A value can span lines, as SDL_GAMECONTROLLERCONFIG does
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let eq = line.firstIndex(of: "="), line[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !line[..<eq].isEmpty {
                last = String(line[..<eq])
                env[last!] = String(line[line.index(after: eq)...])
            } else if let key = last {
                env[key]! += "\n" + line
            }
        }
        return env
    }

    var calls: [String] {
        ((try? String(contentsOf: out.appending(path: "calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: work) }
}

@Suite("Controller layouts for Wine games", .serialized)
struct SDLMappingTests {

    static let allowedKeys: Set<String> = [
        "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick", "leftshoulder", "rightshoulder",
        "dpup", "dpdown", "dpleft", "dpright", "leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger",
        "misc1", "touchpad",
    ]

    // What SDL_GameControllerAddMapping takes: GUID, name, then key:value pairs
    static func check(_ line: String) -> Bool {
        let fields = line.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        guard fields.count > 2, fields[0].count == 32, fields[0].allSatisfy(\.isHexDigit), fields[1] == "*" else { return false }
        return fields.dropFirst(2).allSatisfy { pair in
            let parts = pair.split(separator: ":").map(String.init)
            return parts.count == 2 && allowedKeys.contains(parts[0])
                && parts[1].range(of: #"^[+-]?(b[0-9]+|a[0-9]+)$"#, options: .regularExpression) != nil
        }
    }

    static var crossCircle: ControllerLayout {
        var layout = ControllerLayout()
        layout.set(.south, sends: .east)
        layout.set(.east, sends: .south)
        return layout
    }

    @Test("SDL's GUID for a DualSense over Bluetooth through HIDAPI, with no CRC and no version")
    func guid() {
        #expect(SDLMapping.guid(bus: 0x05, vendor: 0x054c, product: 0x0ce6) == "050000004c050000e60c000000006800")
        #expect(SDLMapping.guid(bus: 0x03, vendor: 0x045e, product: 0x0b12) == "030000005e040000120b000000006800")
    }

    @Test("Cross and Circle swapped: the game's A comes from Circle and its B from Cross")
    func swapCrossCircle() throws {
        let fields = SDLMapping.fields(Self.crossCircle)
        #expect(fields.contains("a:b1,"))
        #expect(fields.contains("b:b0,"))
        #expect(fields.contains("x:b2,") && fields.contains("y:b3,"))
        #expect(fields.contains("leftx:a0,") && fields.contains("righttrigger:a5,"))
        let config = try #require(SDLMapping.config(Self.crossCircle))
        let lines = config.split(separator: "\n").map(String.init)
        #expect(lines.count == SDLMapping.pads.count * 2)
        #expect(lines.allSatisfy(Self.check))
        #expect(lines.contains { $0.hasPrefix("050000004c050000e60c000000006800,*,") && $0.hasSuffix("touchpad:b15,misc1:b16,") })
    }

    @Test("The default layout needs no mapping; Southpaw swaps the stick axes")
    func defaultAndSouthpaw() throws {
        #expect(SDLMapping.config(.standard) == nil)
        let fields = SDLMapping.fields(.preset(.southpaw))
        #expect(fields.contains("leftx:a2,") && fields.contains("rightx:a0,"))
        #expect(fields.contains("leftstick:b8,") && fields.contains("rightstick:b7,"))
        #expect(try #require(SDLMapping.config(.preset(.southpaw))).split(separator: "\n").allSatisfy { Self.check(String($0)) })
    }

    @Test("A trigger that drives a button is read past halfway; a button can drive a trigger")
    func triggers() {
        var layout = ControllerLayout()
        layout.set(.rightTrigger, sends: .south)
        layout.set(.south, sends: .rightTrigger)
        let fields = SDLMapping.fields(layout)
        #expect(fields.contains("a:+a5,"))
        #expect(fields.contains("righttrigger:b0,"))
    }

    @Test("Swap Cross and Circle, then launch: the launch environment carries the mapping")
    func launchEnvironment() async throws {
        let fixture = try LauncherFixture("sdl-launch")
        defer { fixture.remove() }
        let before = try fixture.launch()
        #expect(before["SDL_GAMECONTROLLERCONFIG"] == nil)

        var controls = GameControls()
        controls.layout = Self.crossCircle
        try fixture.files.apply(controls, to: fixture.game)
        let env = try fixture.launch()
        let config = try #require(env["SDL_GAMECONTROLLERCONFIG"])
        #expect(config == SDLMapping.config(Self.crossCircle))
        #expect(config.contains("a:b1,b:b0,"))
        #expect(env["WINEPREFIX"] == fixture.folder.prefix.path(percentEncoded: false))
        #expect(fixture.calls.last?.hasPrefix("game ") == true)
        print("evidence: SDL_GAMECONTROLLERCONFIG first line: \(config.split(separator: "\n")[0])")

        // Back to Default: the next launch has no mapping
        try fixture.files.apply(GameControls(), to: fixture.game)
        #expect(try fixture.launch()["SDL_GAMECONTROLLERCONFIG"] == nil)
    }

    @Test("A launcher written before Controls gets the lines once, before the game starts")
    func olderLauncher() throws {
        let fixture = try LauncherFixture("sdl-old")
        defer { fixture.remove() }
        let current = try String(contentsOf: fixture.folder.launcher, encoding: .utf8)
        let block = GameLauncher.controlsBlock(folder: fixture.folder).joined(separator: "\n") + "\n"
        try current.replacingOccurrences(of: block, with: "").write(to: fixture.folder.launcher, atomically: true, encoding: .utf8)
        #expect(!(try String(contentsOf: fixture.folder.launcher, encoding: .utf8)).contains(GameLauncher.controlsMarker))

        var controls = GameControls()
        controls.layout = .preset(.southpaw)
        try fixture.files.apply(controls, to: fixture.game)
        try fixture.files.apply(controls, to: fixture.game)
        let text = try String(contentsOf: fixture.folder.launcher, encoding: .utf8)
        #expect(text.components(separatedBy: GameLauncher.controlsMarker).count == 2)
        let lines = text.split(separator: "\n").map(String.init)
        let marker = try #require(lines.firstIndex(of: GameLauncher.controlsMarker))
        let exec = try #require(lines.firstIndex { $0.hasPrefix("exec ") })
        #expect(marker < exec)
        #expect(try fixture.launch()["SDL_GAMECONTROLLERCONFIG"] == SDLMapping.config(.preset(.southpaw)))
    }

    @Test("Choices are kept per game; a game back to every default leaves the file")
    func store() async throws {
        let work = try scratchDirectory("controls-store")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = ControlsStore(folder: work)
        var controls = GameControls()
        controls.layout = .preset(.swapAB)
        try await store.set(controls, for: "console:snes:x")
        #expect(await ControlsStore(folder: work).controls("console:snes:x") == controls)
        try await store.set(GameControls(), for: "console:snes:x")
        #expect(await ControlsStore(folder: work).all().isEmpty)
    }

    @Test("Who handles the layout: Steam Input, Cartouche or RetroArch")
    func handler() {
        #expect(ControlsHandler(.steam(1_145_360, name: "Hades", installed: true)) == .steamInput)
        #expect(ControlsHandler(Game(id: "installer:x", source: .installer, name: "X", installed: true)) == .cartouche)
        #expect(ControlsHandler(Game(id: "console:snes:y", source: .console("snes"), name: "Y", installed: true)) == .retroArch)
    }
}
