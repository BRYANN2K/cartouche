import Foundation

// Starts a console game on the chosen RetroArch: over MCP when the build has
// it, with -L <core> <file> when it does not
public struct ConsoleLauncher: Sendable {

    public let paths: RetroArchPaths
    public let app: URL
    public let capabilities: RetroArchCapabilities
    public var environment: [String: String]?

    public init(paths: RetroArchPaths, app: URL, capabilities: RetroArchCapabilities) {
        self.paths = paths
        self.app = app
        self.capabilities = capabilities
    }

    public func launch() -> RetroArchLaunch {
        var config = AppendConfig(paths: paths)
        // Without MCP, the UDP commands are what is left to talk to it
        config.networkCommands = !capabilities.mcp
        var launch = RetroArchLaunch(executable: app, config: config, mcp: capabilities.mcp)
        launch.environment = Self.environment(environment ?? ProcessInfo.processInfo.environment, home: paths.home)
        return launch
    }

    // RetroArch makes its default folders under ~ before it reads any config,
    // and macOS RetroArch finds ~ through Foundation, which reads
    // CFFIXED_USER_HOME rather than HOME. Both point into Cartouche's folder,
    // so the user's own ~/Documents/RetroArch is never made or touched.
    public static func environment(_ base: [String: String], home: URL) -> [String: String] {
        var environment = base
        environment["HOME"] = home.path(percentEncoded: false)
        environment["CFFIXED_USER_HOME"] = home.path(percentEncoded: false)
        return environment
    }

    public func play(core: URL, content: URL) async throws -> RetroArchSession {
        let session = RetroArchSession(launch: launch())
        if capabilities.mcp {
            try await session.start()
            do {
                try await session.load(core: core, content: content)
            } catch {
                _ = await session.stop()
                throw error
            }
        } else {
            try await session.start(core: core, content: content)
        }
        return session
    }
}
