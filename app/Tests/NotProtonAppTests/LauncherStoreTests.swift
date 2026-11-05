import Foundation
import InstallerKit
import Testing

@testable import NotProtonApp

// The commands a launcher prefix takes, the URIs its protocol answers to, and the
// registry it keeps. Every path here is a hand-written fixture; no Wine ever runs.
@Suite("Launcher stores", .serialized)
struct LauncherStoreTests {

    final class Recorder: LauncherRun, @unchecked Sendable {
        var commands: [(command: ClientCommand, started: Bool)] = []
        var outputs: [ClientOutput] = []
        var onCommand: (@Sendable (ClientCommand, Bool) -> Void)? = nil

        func run(_ command: ClientCommand) async throws -> ClientOutput {
            commands.append((command, false)); onCommand?(command, false)
            return outputs.isEmpty ? ClientOutput(status: 0, stdout: "", stderr: "") : outputs.removeFirst()
        }
        func start(_ command: ClientCommand) async throws -> any LauncherProcess {
            commands.append((command, true)); onCommand?(command, true)
            return FakeProcess()
        }
    }

    final class FakeProcess: LauncherProcess, @unchecked Sendable {
        private(set) var stopped = false
        var isRunning: Bool { !stopped }
        func wait() async -> Int32 { 0 }
        func stop() { stopped = true }
    }

    static let wine = WineRunner(root: URL(filePath: "/runners/wine"), loader: URL(filePath: "/runners/wine/lib/wine/x86_64-unix/wine"),
                                 server: URL(filePath: "/runners/wine/bin/wineserver"), dllPath: "/runners/wine/lib/wine/x86_64-windows")

    private static func launcher(_ store: GameSource, in folder: URL, run: Recorder) -> StoreLauncher {
        var launcher = StoreLauncher(store: store, folder: folder, wine: { wine }, run: run)
        launcher.boot = { _, _, _, _ in }
        return launcher
    }

    @Test("The launcher's own prefix, exe, log and the vendor's install flags")
    func paths() throws {
        let folder = URL(filePath: "/tmp/stores/ubisoft/launcher")
        let ubisoft = StoreLauncher(store: .ubisoft, folder: folder, wine: { Self.wine })
        #expect(ubisoft.prefix == folder.appending(path: "pfx"))
        #expect(ubisoft.log == folder.appending(path: "launcher.log"))
        #expect(ubisoft.executable.path(percentEncoded: false)
            .hasSuffix("drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"))
        #expect(ubisoft.installerArguments == ["/S"])
        let ea = StoreLauncher(store: .ea, folder: URL(filePath: "/tmp/stores/ea/launcher"), wine: { Self.wine })
        #expect(ea.executable.path(percentEncoded: false)
            .hasSuffix("drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe"))
        #expect(ea.installerArguments == [])
        #expect(!ubisoft.installed && !ea.installed)
        // B7: EA's launch env slows the WMI path through real, drained stderr writes
        #expect(ea.launchEnvironment["WINEDEBUG"] == "+wbemprox")
        #expect(ea.launchEnvironment["QMLSCENE_DEVICE"] == "softwarecontext")
        #expect(ubisoft.launchEnvironment["WINEDEBUG"] == nil)
        // B9: both launchers keep their CEF GPU service in-process and off, or the page stays black
        #expect(ubisoft.launchArguments == ["--in-process-gpu", "--disable-gpu"])
        #expect(ea.launchArguments == ["--in-process-gpu", "--disable-gpu"])
    }

    @Test("The URIs of the registered protocols, and the official web stores")
    func links() {
        #expect(LauncherLinks.open(.ubisoft) == "uplay://")
        #expect(LauncherLinks.launch(.ubisoft, id: "540") == "uplay://launch/540/0")
        #expect(LauncherLinks.install(.ubisoft, id: "720") == "uplay://install/720")
        #expect(LauncherLinks.uninstall(.ubisoft, id: "540") == "uplay://uninstall/540")
        #expect(LauncherLinks.gamePage(.ubisoft, launchID: "540") == "uplay://open/game/540")
        #expect(LauncherLinks.open(.ea) == "origin2://")
        #expect(LauncherLinks.launch(.ea, id: "Origin.OFR.50.00040000") == "origin2://game/launch?offerIds=Origin.OFR.50.00040000")
        #expect(LauncherLinks.install(.ea, id: "Origin.OFR.50.00040000") == "origin2://game/launch?offerIds=Origin.OFR.50.00040000&autoDownload=1")
        #expect(LauncherLinks.uninstall(.ea, id: "x") == nil)
        #expect(LauncherLinks.gamePage(.ea, launchID: "x") == nil)
        #expect(LauncherLinks.storePage(.ubisoft).absoluteString == "https://store.ubisoft.com")
        #expect(LauncherLinks.storePage(.ea, slug: "the-sims-4").absoluteString == "https://www.ea.com/games/the-sims-4")
        #expect(LauncherLinks.storePage(.ea, slug: nil).absoluteString == "https://www.ea.com/games")
    }

    @Test("install() boots the prefix, runs the installer silently under Rosetta, and requires the launcher exe")
    func install() async throws {
        let root = try scratchDirectory("launcher-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "launcher")
        let recorder = Recorder()
        let launcher = Self.launcher(.ubisoft, in: folder, run: recorder)
        let installer = root.appending(path: "UbisoftConnectInstaller.exe")
        try Data("MZ".utf8).write(to: installer)
        let boots = MutexBox<[URL]>([])
        var tested = launcher
        tested.boot = { _, prefix, _, _ in boots.value.append(prefix) }
        recorder.onCommand = { _, _ in
            try? FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data())
        }
        try await tested.install(from: installer)
        #expect(boots.value == [launcher.prefix])
        #expect(launcher.installed)
        let command = try #require(recorder.commands.first?.command)
        #expect(!recorder.commands[0].started)
        #expect(command.executable == URL(filePath: "/usr/bin/arch"))
        #expect(command.arguments[0] == "-x86_64")
        #expect(command.arguments[1] == Self.wine.loader.path(percentEncoded: false))
        #expect(command.arguments[2] == installer.path(percentEncoded: false))
        #expect(command.arguments[3] == "/S")
        #expect(command.environment["WINEPREFIX"] == launcher.prefix.path(percentEncoded: false))
        #expect(command.environment["WINELOADER"] == Self.wine.loader.path(percentEncoded: false))
    }

    @Test("install() fails when the installer leaves no launcher exe behind")
    func installLeavesNothing() async throws {
        let root = try scratchDirectory("launcher-install-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let launcher = Self.launcher(.ea, in: root.appending(path: "launcher"), run: recorder)
        let installer = root.appending(path: "EAInstaller.exe")
        try Data("MZ".utf8).write(to: installer)
        await #expect(throws: StoreError.self) { try await launcher.install(from: installer) }
        recorder.outputs = [ClientOutput(status: 1, stdout: "", stderr: "cabinet corrupt")]
        await #expect(throws: StoreError.self) { try await launcher.install(from: installer) }
    }

    @Test("open() starts the launcher exe and hands it the URI; without an install it refuses")
    func open() async throws {
        let root = try scratchDirectory("launcher-open")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let launcher = Self.launcher(.ubisoft, in: root.appending(path: "launcher"), run: recorder)
        await #expect(throws: StoreError.self) { _ = try await launcher.open() }
        try FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data())
        let process = try await launcher.open("uplay://launch/540/0")
        #expect(process.isRunning)
        let command = try #require(recorder.commands.last?.command)
        #expect(recorder.commands.last?.started == true)
        #expect(command.arguments == ["-x86_64", Self.wine.loader.path(percentEncoded: false),
                                      launcher.executable.path(percentEncoded: false), "uplay://launch/540/0",
                                      "--in-process-gpu", "--disable-gpu"])
        #expect(command.environment["WINEPREFIX"] == launcher.prefix.path(percentEncoded: false))
        let plain = try await launcher.open()
        #expect(plain.isRunning)
        #expect(recorder.commands.last?.command.arguments.last == "--disable-gpu")
    }

    @Test("open() hands the launcher's env the game's graphics backend; none without one")
    func openBackend() async throws {
        let root = try scratchDirectory("launcher-open-backend")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var launcher = Self.launcher(.ubisoft, in: root.appending(path: "launcher"), run: recorder)
        // A DXMT install as BackendInstaller leaves it: the receipt plus its DLL folders
        let backends = root.appending(path: "backends")
        let dxmt = backends.appending(path: "dxmt/x86_64-windows")
        try FileManager.default.createDirectory(at: dxmt, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dxmt.appending(path: "d3d11.dll").path(percentEncoded: false), contents: Data())
        FileManager.default.createFile(atPath: dxmt.appending(path: "winemetal.dll").path(percentEncoded: false), contents: Data())
        try JSONEncoder().encode(BackendInstaller.Receipt(backend: .dxmt, version: "1", archiveSHA256: "a", files: [:]))
            .write(to: backends.appending(path: "dxmt/.cartouche-backend.json"))
        launcher.backends = backends
        launcher.backend = { .dxmt }
        launcher.prepareGraphics = { wine, _, _, _ in wine }
        try FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data())
        try FileManager.default.createDirectory(at: launcher.prefix.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true)
        _ = try await launcher.open()
        let command = try #require(recorder.commands.last?.command)
        #expect(command.environment["CX_GRAPHICS_BACKEND"] == "dxmt")
        #expect(command.environment["WINEDLLOVERRIDES"]?.contains("d3d11,dxgi,d3d10core=b") == true)
        #expect(command.environment["WINEDLLPATH"]?.hasPrefix(dxmt.path(percentEncoded: false)) == true)
        // DXMT's winemetal.dll landed in the launcher's own prefix, for the games it parents
        #expect(FileManager.default.fileExists(atPath: launcher.prefix.appending(path: "drive_c/windows/system32/winemetal.dll").path(percentEncoded: false)))
        let plain = Self.launcher(.ubisoft, in: root.appending(path: "launcher"), run: recorder)
        _ = try await plain.open()
        #expect(recorder.commands.last?.command.environment["CX_GRAPHICS_BACKEND"] == nil)
    }

    @Test("EA's install is the real recipe: bare bootstrapper, versioned dir linked stable, stray client killed, service key")
    func eaInstall() async throws {
        let root = try scratchDirectory("launcher-ea-install")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "launcher")
        let recorder = Recorder()
        let launcher = Self.launcher(.ea, in: folder, run: recorder)
        let installer = root.appending(path: "EAappInstaller.exe")
        try Data("MZ".utf8).write(to: installer)
        recorder.onCommand = { command, _ in
            let pfx = launcher.prefix
            if command.arguments.last == installer.path(percentEncoded: false) {
                // Burn really installs under the shipped runner — into the versioned dir,
                // without the stable EA Desktop\EA Desktop the MSI junctions on Windows (B-E2)
                let app = pfx.appending(path: "drive_c/Program Files/Electronic Arts/EA Desktop/13.813.1.6327/EA Desktop/EADesktop.exe")
                try? FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: app.path(percentEncoded: false), contents: Data("real".utf8))
                // The vendor also drops a same-named compat stub — never the copy source
                let stub = app.deletingLastPathComponent().appending(path: "compatibility32/EADesktop.exe")
                try? FileManager.default.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: stub.path(percentEncoded: false), contents: Data("stub".utf8))
                let msi = pfx.appending(path: "drive_c/ProgramData/Package Cache/{GUID}/v13/EAapp-13.813.1.6327-16195906.msi")
                try? FileManager.default.createDirectory(at: msi.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: msi.path(percentEncoded: false), contents: Data())
            }
        }
        try await launcher.install(from: installer)
        #expect(launcher.installed)
        #expect(FileManager.default.fileExists(atPath: launcher.executable.path(percentEncoded: false)))
        // The stable dir was copied from the versioned one — the real exe, not the stub
        #expect((try? Data(contentsOf: launcher.executable)).map { String(decoding: $0, as: UTF8.self) } == "real")
        let kinds = recorder.commands.map { $0.command.arguments }
        // 1: bare bootstrapper run — no silent flags (its BA refuses them)
        #expect(kinds[0].contains(installer.path(percentEncoded: false)) && !kinds[0].contains("/passive"))
        // 2: the auto-started client is killed — only the service may stay
        #expect(kinds.contains { $0.contains("taskkill") && $0.contains("EADesktop.exe") })
        // No msiexec when Burn already installed: the versioned dir answers first (B-E2)
        #expect(!kinds.contains { $0.contains("msiexec") })
        // 3+: reg writes for the service and the three protocols
        let regs = kinds.filter { $0.contains("reg") }
        #expect(regs.contains { $0.contains("EABackgroundService") || $0.joined().contains("EABackgroundService") })
        #expect(regs.contains { $0.joined().contains("HKCR\\origin2") })
        #expect(regs.contains { $0.joined().contains("HKCR\\link2ea") })
        #expect(regs.contains { $0.joined().contains("HKCR\\eadesktop") })
        // The exe then opens with the software-render Qt env
        var tested = launcher
        tested.preflight = {}
        _ = try await tested.open()
        let start = try #require(recorder.commands.last?.command)
        #expect(start.environment["QT_QUICK_BACKEND"] == "software")
        #expect(start.environment["QT_OPENGL"] == "software")
        #expect(Array(start.arguments.suffix(3)) == [launcher.executable.path(percentEncoded: false), "--in-process-gpu", "--disable-gpu"])
    }

    @Test("The MSI admin-extract stays the fallback when Burn left no client behind")
    func eaInstallMSIFallback() async throws {
        let root = try scratchDirectory("launcher-ea-msi")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "launcher")
        let recorder = Recorder()
        let launcher = Self.launcher(.ea, in: folder, run: recorder)
        let installer = root.appending(path: "EAappInstaller.exe")
        try Data("MZ".utf8).write(to: installer)
        recorder.onCommand = { command, _ in
            let pfx = launcher.prefix
            if command.arguments.contains("msiexec") {
                // msiexec /a drops the app tree under drive_c/eaadmin (W1's path)
                let app = pfx.appending(path: "drive_c/eaadmin/EA Desktop/EADesktop.exe")
                try? FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: app.path(percentEncoded: false), contents: Data())
            } else if command.arguments.last == installer.path(percentEncoded: false) {
                let msi = pfx.appending(path: "drive_c/ProgramData/Package Cache/{GUID}/v13/EAapp-13.813.1.6327-16195906.msi")
                try? FileManager.default.createDirectory(at: msi.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: msi.path(percentEncoded: false), contents: Data())
            }
        }
        try await launcher.install(from: installer)
        #expect(launcher.installed)
        let msiexec = try #require(recorder.commands.map(\.command.arguments).first { $0.contains("msiexec") })
        #expect(msiexec.contains("/a") && msiexec.contains("/qn"))
        #expect(msiexec.contains { $0.contains("EAapp-13.813.1.6327-16195906.msi") })
        #expect(msiexec.contains("TARGETDIR=C:\\eaadmin") && !msiexec.contains("/i"))
    }

    @Test("EA's preflight fails the open with the holding process's name; Ubisoft has none")
    func eaPreflight() async throws {
        let root = try scratchDirectory("launcher-preflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var launcher = Self.launcher(.ea, in: root.appending(path: "launcher"), run: recorder)
        try FileManager.default.createDirectory(at: launcher.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.executable.path(percentEncoded: false), contents: Data())
        launcher.preflight = { throw StoreError.failed("port 3216 held by prometheemcp") }
        await #expect(throws: StoreError.self) { _ = try await launcher.open() }
        #expect(recorder.commands.last?.started != true)
        // The real check: a port we hold is named, a free one passes
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        #expect(fd >= 0)
        #expect(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0)
        var bound = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(fd, withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &size)
        let held = in_port_t(bigEndian: bound.sin_port)
        #expect(await EAPreflight.holder(of: held) != nil)
        #expect(await EAPreflight.holder(of: 39007) == nil)
    }

    // A system.reg excerpt, hand-written in the exact layout Wine writes: doubled
    // backslashes in key paths and values, #time lines between them.
    static let systemReg = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\Machine

    [Software\\Wow6432Node\\Ubisoft\\Launcher] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher"
    "Version"="16302"

    [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs] 1764000000
    #time=1dc9a8b3c000000

    [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\720] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games\\Harbor Lords"

    [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games\\Far Shore"

    [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Uplay Install 720] 1764000000
    #time=1dc9a8b3c000000
    "InstallLocation"="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games\\Harbor Lords"
    "DisplayName"="Harbor Lords"

    [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Uplay Install 13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallLocation"="C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games\\Far Shore"
    "DisplayName"="Far Shore"
    """#

    // The same prefix while 720 is still downloading: its Installs entry, no Uninstall one
    static let systemRegPending720 = """
    WINE REGISTRY Version 2
    ;; All keys relative to \\Machine

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher"
    "Version"="16302"

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs] 1764000000
    #time=1dc9a8b3c000000

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs\\\\720] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher\\\\games\\\\Harbor Lords"

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs\\\\13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher\\\\games\\\\Far Shore"

    [Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Uplay Install 13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallLocation"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher\\\\games\\\\Far Shore"
    "DisplayName"="Far Shore"
    """

    // And once 720 is fully gone: neither its Installs entry nor its Uninstall one remains
    static let systemRegWithout720 = """
    WINE REGISTRY Version 2
    ;; All keys relative to \\Machine

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher"
    "Version"="16302"

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs] 1764000000
    #time=1dc9a8b3c000000

    [Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs\\\\13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallDir"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher\\\\games\\\\Far Shore"

    [Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Uplay Install 13504] 1764000000
    #time=1dc9a8b3c000000
    "InstallLocation"="C:\\\\Program Files (x86)\\\\Ubisoft\\\\Ubisoft Game Launcher\\\\games\\\\Far Shore"
    "DisplayName"="Far Shore"
    """

    @Test("system.reg sections parse, values unescape, and Installs keys give game dirs")
    func registry() throws {
        let sections = WineRegistry.sections(Self.systemReg)
        let launcher = try #require(sections[#"Software\Wow6432Node\Ubisoft\Launcher"#])
        #expect(launcher["installdir"] == #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher"#)
        #expect(launcher["version"] == "16302")
        let installs = WineRegistry.installedGames(in: Self.systemReg, under: #"Software\Wow6432Node\Ubisoft\Launcher\Installs"#)
        #expect(installs == ["720": #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Harbor Lords"#,
                             "13504": #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Far Shore"#])
        #expect(WineRegistry.values(Self.systemReg, in: #"SOFTWARE\WOW6432NODE\UBISOFT\LAUNCHER"#)?["version"] == "16302")
        let prefix = URL(filePath: "/tmp/pfx")
        #expect(WinePath.unix(installs["720"]!, prefix: prefix)
            == prefix.appending(path: "drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Harbor Lords"))
        #expect(WinePath.unix(#"C:\..\..\evil"#, prefix: prefix) == nil)
        #expect(WinePath.unix(#"D:\Games\X"#, prefix: prefix) == nil)
    }

    @Test("read() decodes a UTF-16 system.reg as Wine writes it")
    func registryUTF16() throws {
        let prefix = try scratchDirectory("launcher-reg16").appending(path: "pfx")
        defer { try? FileManager.default.removeItem(at: prefix.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Self.systemReg.write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf16LittleEndian)
        let sections = WineRegistry.sections(try #require(WineRegistry.read(prefix: prefix)))
        #expect(sections[#"Software\Wow6432Node\Ubisoft\Launcher"#]?["version"] == "16302")
    }
}
