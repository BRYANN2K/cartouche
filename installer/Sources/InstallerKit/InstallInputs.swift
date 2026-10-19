// What one install run is made of, and how it becomes a Wine command line.
// A retry changes these inputs and runs again.

import Foundation

public struct InstallInputs: Sendable, Equatable, Codable {
    public var runnerID: String
    // C:\Games\<Name>: short and ASCII, a classic cause of unarc errors otherwise.
    public var installDir: String
    public var mode: InnoCommand.Mode
    public var language: String?
    public var log: String = #"C:\installer.log"#
    // Check the parts' checksums again before running.
    public var verifyFirst = false
    // Cores Wine shows the installer. Nil is all of them.
    public var threads: Int?
    // What the decompressors' CLS.ini may take, in percent of RAM. Nil keeps the installer's value.
    public var memoryPercent: Int?
    // Run setup.exe from a drive letter mapped to its folder instead of its full path.
    public var shortSource = false

    public init(runnerID: String, gameName: String, mode: InnoCommand.Mode = .guided, language: String? = nil) {
        self.runnerID = runnerID
        self.installDir = #"C:\Games\"# + WinePath.folderName(gameName)
        self.mode = mode
        self.language = language
    }

    public var innoArguments: [String] {
        InnoCommand(installDir: installDir, mode: mode, language: language, log: log).arguments
    }
}

public enum WinePath {

    // Letters, digits, spaces and a few marks, at most 40 characters.
    public static func folderName(_ game: String, limit: Int = 40) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_.'&()"))
        let ascii = game.folding(options: .diacriticInsensitive, locale: nil)
        var name = String(String.UnicodeScalarView(ascii.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }))
        name = name.split(separator: " ").joined(separator: " ")
        name = String(name.prefix(limit)).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
        return name.isEmpty ? "Game" : name
    }

    // C:\Games\X → <prefix>/drive_c/Games/X. Only drive C, which is inside the prefix.
    public static func unix(_ windows: String, prefix: URL) -> URL? {
        let path = windows.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 2, path.lowercased().hasPrefix("c:") else { return nil }
        let rest = path.dropFirst(2).split(separator: "/").map(String.init)
        return rest.reduce(prefix.appending(path: "drive_c")) { $0.appending(path: $1) }
    }

    public static func windows(_ unix: URL, prefix: URL) -> String? {
        let base = prefix.appending(path: "drive_c").standardizedFileURL.path(percentEncoded: false)
        let path = unix.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(base) else { return nil }
        return "C:" + path.dropFirst(base.count).replacingOccurrences(of: "/", with: "\\")
    }
}

// One process to start: what InstallRunner launches and tests compare.
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

// The Wine side of a runner, as the app resolves it from the runner registry.
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

    // The drive letter the short source path uses.
    public static let sourceDrive = "s:"

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

    // wineboot --init makes the new prefix without the Mono and Gecko prompts.
    public static func createPrefix(runner: WineRunner, prefix: URL, base: [String: String]) -> InstallLaunch {
        var env = environment(runner: runner, prefix: prefix, inputs: nil, base: base)
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml="
        return InstallLaunch(executable: rosetta[0], arguments: Array(rosetta.dropFirst()) + [runner.loader.path(percentEncoded: false), "wineboot", "--init"], environment: env)
    }

    public static func setupPath(_ setup: URL, inputs: InstallInputs) -> String {
        inputs.shortSource ? sourceDrive.uppercased() + "\\" + setup.lastPathComponent : setup.path(percentEncoded: false)
    }

    public static func runSetup(
        _ setup: URL, runner: WineRunner, prefix: URL, inputs: InstallInputs, base: [String: String]
    ) -> InstallLaunch {
        InstallLaunch(
            executable: rosetta[0],
            arguments: Array(rosetta.dropFirst()) + [runner.loader.path(percentEncoded: false), setupPath(setup, inputs: inputs)] + inputs.innoArguments,
            environment: environment(runner: runner, prefix: prefix, inputs: inputs, base: base),
            currentDirectory: setup.deletingLastPathComponent()
        )
    }

    // dosdevices/s: → the installer's folder, for the short source path.
    public static func mapSource(_ folder: URL, prefix: URL) throws {
        let link = prefix.appending(path: "dosdevices").appending(path: sourceDrive)
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: folder)
    }
}
