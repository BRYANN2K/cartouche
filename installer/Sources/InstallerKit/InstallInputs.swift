// What one install run is made of; a retry changes these inputs and runs again.

import Foundation

public struct InstallInputs: Sendable, Equatable, Codable {
    public var runnerID: String
    // C:\Games\<Name>: short and ASCII, a classic cause of unarc errors otherwise.
    public var installDir: String
    public var mode: InnoCommand.Mode
    public var language: String?
    public var log: String = #"C:\installer.log"#
    public var verifyFirst = false
    // Cores Wine shows the installer. Nil is all of them.
    public var threads: Int?
    // What the decompressors' CLS.ini may take, in percent of RAM. Nil keeps the installer's value.
    public var memoryPercent: Int?
    // Run setup.exe from a drive letter mapped to its folder instead of its full path.
    public var shortSource = false
    // The installer unpacks through its own helper processes (ExternalUnpacker), not Inno's extractor.
    public var externalUnpacker = false

    public init(runnerID: String, gameName: String, mode: InnoCommand.Mode = .guided, language: String? = nil) {
        self.runnerID = runnerID
        self.installDir = #"C:\Games\"# + WinePath.folderName(gameName)
        self.mode = mode
        self.language = language
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        runnerID = try box.decode(String.self, forKey: .runnerID)
        installDir = try box.decode(String.self, forKey: .installDir)
        mode = try box.decode(InnoCommand.Mode.self, forKey: .mode)
        language = try box.decodeIfPresent(String.self, forKey: .language)
        log = try box.decodeIfPresent(String.self, forKey: .log) ?? #"C:\installer.log"#
        verifyFirst = try box.decodeIfPresent(Bool.self, forKey: .verifyFirst) ?? false
        threads = try box.decodeIfPresent(Int.self, forKey: .threads)
        memoryPercent = try box.decodeIfPresent(Int.self, forKey: .memoryPercent)
        shortSource = try box.decodeIfPresent(Bool.self, forKey: .shortSource) ?? false
        externalUnpacker = try box.decodeIfPresent(Bool.self, forKey: .externalUnpacker) ?? false
    }

    // What an external unpacker needs to work: short ASCII paths, its own UI, and a memory
    // share that fits a 32-bit address space. The prefix preparation adds the rest.
    public mutating func applyUnpackerProfile(ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        externalUnpacker = true
        installDir = #"C:\G\"# + Self.shortName(installDir)
        shortSource = true
        mode = .guided
        memoryPercent = min(memoryPercent ?? 90, ExternalUnpacker.memoryPercent(ramBytes: ramBytes))
    }

    public var innoArguments: [String] {
        InnoCommand(installDir: installDir, mode: externalUnpacker ? .guided : mode, language: language, log: log).arguments
    }
}

public enum WinePath {

    public static func folderName(_ game: String, limit: Int = 40) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_.'&()"))
        let ascii = game.folding(options: .diacriticInsensitive, locale: nil)
        var name = String(String.UnicodeScalarView(ascii.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }))
        name = name.split(separator: " ").joined(separator: " ")
        name = String(name.prefix(limit)).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
        return name.isEmpty ? "Game" : name
    }

    // C:\Games\X → <prefix>/drive_c/Games/X. Only drive C, which is inside the prefix. .lnk and registry paths are installer data: "." and ".." are dropped so the result can never leave drive_c.
    public static func unix(_ windows: String, prefix: URL) -> URL? {
        let path = windows.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 2, path.lowercased().hasPrefix("c:") else { return nil }
        let rest = path.dropFirst(2).split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
        return rest.reduce(prefix.appending(path: "drive_c")) { $0.appending(path: $1) }
    }

    public static func windows(_ unix: URL, prefix: URL) -> String? {
        let base = prefix.appending(path: "drive_c").standardizedFileURL.path(percentEncoded: false)
        let path = unix.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(base) else { return nil }
        return "C:" + path.dropFirst(base.count).replacingOccurrences(of: "/", with: "\\")
    }
}

public struct InstallLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?

    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.currentDirectory = currentDirectory
    }
}

public struct WineRunner: Sendable, Equatable {
    public let root: URL
    public let loader: URL
    public let server: URL
    public let dllPath: String

    public init(root: URL, loader: URL, server: URL, dllPath: String) {
        self.root = root; self.loader = loader; self.server = server; self.dllPath = dllPath
    }
}

public enum WineInstall {

    public static let sourceDrive = "s:"

    // The setup's temp dir when an external unpacker runs: three characters, no long user paths.
    public static let shortTemp = #"C:\T"#

    // Errors of every channel, plus structured exception handling, DLL loads and process
    // starts/exits: the next failure names what died. The output log is capped by the run.
    // CARTOUCHE_WINEDEBUG (open --env) widens the channels when a crash needs a deeper trace
    public static var setupDebug: String {
        ProcessInfo.processInfo.environment["CARTOUCHE_WINEDEBUG"] ?? "err+all,+seh,+loaddll,+process"
    }

    // Rosetta always: the decompressors are x86 programs and run most reliably translated.
    public static let rosetta = ["/usr/bin/arch", "-x86_64"]

    public static func environment(
        runner: WineRunner, prefix: URL, inputs: InstallInputs?, base: [String: String]
    ) -> [String: String] {
        var env = base
        let root = runner.root.path(percentEncoded: false)
        env["CX_ROOT"] = root
        env["WINELOADER"] = runner.loader.path(percentEncoded: false)
        env["WINESERVER"] = runner.server.path(percentEncoded: false)
        env["WINEDLLPATH"] = runner.dllPath
        env["WINEPREFIX"] = prefix.path(percentEncoded: false)
        env["WINEDEBUG"] = "-all"
        // No menu entries or Mac launchers from the installer's shortcuts; the .lnk files are still written.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        env["PATH"] = "\(root)/bin:" + (base["PATH"] ?? "/usr/bin:/bin")
        if let threads = inputs?.threads {
            env["WINE_CPU_TOPOLOGY"] = "\(threads):" + (0..<threads).map(String.init).joined(separator: ",")
        }
        return env
    }

    // drive_c/T for the Windows-side temp dir; C:\T is what TEMP/TMP point at.
    public static func makeTemp(prefix: URL) throws {
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "drive_c/T"), withIntermediateDirectories: true)
    }

    // wineboot -u creates or updates the prefix. Mono and Gecko stays enabled: a game may ask for them.
    public static func createPrefix(runner: WineRunner, prefix: URL, base: [String: String]) -> InstallLaunch {
        var env = environment(runner: runner, prefix: prefix, inputs: nil, base: base)
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        return InstallLaunch(executable: rosetta[0], arguments: Array(rosetta.dropFirst()) + [runner.loader.path(percentEncoded: false), "wineboot", "-u"], environment: env)
    }

    public static func setupPath(_ setup: URL, inputs: InstallInputs) -> String {
        inputs.shortSource ? sourceDrive.uppercased() + "\\" + setup.lastPathComponent : setup.path(percentEncoded: false)
    }

    public static func runSetup(
        _ setup: URL, runner: WineRunner, prefix: URL, inputs: InstallInputs, base: [String: String]
    ) -> InstallLaunch {
        var env = environment(runner: runner, prefix: prefix, inputs: inputs, base: base)
        env["WINEDEBUG"] = setupDebug
        if inputs.externalUnpacker {
            env["TEMP"] = shortTemp
            env["TMP"] = shortTemp
        }
        return InstallLaunch(
            executable: rosetta[0],
            arguments: Array(rosetta.dropFirst()) + [runner.loader.path(percentEncoded: false), setupPath(setup, inputs: inputs)] + inputs.innoArguments,
            environment: env,
            currentDirectory: setup.deletingLastPathComponent()
        )
    }

    // The driver's run for one part: from the helpers dir, over the mapped source drive, with the
    // helpers' scratch dir as TEMP/TMP and Wine's own log channels off — the helpers write enough
    // output themselves and a WINEDEBUG trace slows the decompression measurably.
    public static func runUnpackDriver(
        part: URL, plan: DirectUnpackPlan, installDir: String,
        runner: WineRunner, prefix: URL, inputs: InstallInputs?, base: [String: String]
    ) -> InstallLaunch {
        var env = environment(runner: runner, prefix: prefix, inputs: inputs, base: base)
        env["WINEDEBUG"] = "-all"
        env["TEMP"] = shortTemp
        env["TMP"] = shortTemp
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        let config = DirectUnpack.helperDir + "\\" + plan.arcConfig
        return InstallLaunch(
            executable: rosetta[0],
            arguments: Array(rosetta.dropFirst()) + [runner.loader.path(percentEncoded: false),
                DirectUnpack.helperDir + "\\" + DirectUnpack.driverName]
                + DirectUnpack.arguments(installDir: installDir, tempDir: shortTemp, config: config)
                + ["--", sourceDrive.uppercased() + "\\" + part.lastPathComponent],
            environment: env,
            currentDirectory: prefix.appending(path: DirectUnpack.helperUnixDir)
        )
    }

    public static func mapSource(_ folder: URL, prefix: URL) throws {
        let link = prefix.appending(path: "dosdevices").appending(path: sourceDrive)
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
    }
}
