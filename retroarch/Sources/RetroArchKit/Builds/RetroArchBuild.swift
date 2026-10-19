import Foundation

// Which RetroArch Cartouche runs, as chosen in Settings > Consoles
public enum RetroArchChoice: Codable, Sendable, Equatable, Hashable {
    // Built from vendor/RetroArch, in Cartouche.app/Contents/Helpers
    case included
    // A stable release from the libretro buildbot, downloaded by Cartouche
    case official(version: String)
    // A RetroArch.app the user already has
    case custom(path: String)
}

// What a build can do, read from its own --help and --version
public struct RetroArchCapabilities: Sendable, Equatable {
    public var mcp: Bool
    public var version: String?

    public init(mcp: Bool, version: String?) {
        self.mcp = mcp
        self.version = version
    }
}

// Features that drive RetroArch over MCP, and so need a build that has it
public enum ConsoleFeature: String, CaseIterable, Sendable, Identifiable {
    case continueFrom
    case coachMode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .continueFrom: String(localized: "Continue From", bundle: .module)
        case .coachMode: String(localized: "Coach mode", bundle: .module)
        }
    }

    public var needsMCP: Bool { true }

    public func available(with capabilities: RetroArchCapabilities?) -> Bool {
        !needsMCP || capabilities?.mcp == true
    }
}

public enum BuildProbe {

    // Runs the build twice, for --version and --help; nil if it is not RetroArch
    public static func capabilities(of app: URL) async -> RetroArchCapabilities? {
        let executable = RetroArchLaunch.binary(app)
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else { return nil }
        guard let help = await output(executable, "--help") else { return nil }
        let version = await output(executable, "--version").flatMap { text in
            text.split(separator: "\n").first { $0.hasPrefix("Version: ") }
                .flatMap { $0.dropFirst("Version: ".count).split(separator: " ").first.map(String.init) }
        }
        guard help.contains("libretro") || version != nil else { return nil }
        return RetroArchCapabilities(mcp: help.contains("--mcp-stdio"), version: version)
    }

    // Bounded: a GUI build that does not exit is stopped after the limit
    static func output(_ executable: URL, _ argument: String, limit: Duration = .seconds(10)) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let reading = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let deadline = ContinuousClock.now + limit
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { process.terminate() }
        return String(decoding: await reading.value, as: UTF8.self)
    }
}
