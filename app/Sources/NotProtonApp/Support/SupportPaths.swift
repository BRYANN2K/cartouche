// Path construction for the Cartouche support directory and Steam

import CartoucheIdentity
import Foundation

enum SupportPaths {

    // Shared with the dylib through cartouche_identity.h
    static let supportDirName = CARTOUCHE_DIR_NAME
    static let dylibName = CARTOUCHE_DYLIB_NAME
    static let steamPrefix = CARTOUCHE_STEAM_PREFIX
    static let toolPrefix = CARTOUCHE_TOOL_PREFIX
    static let fpsCounterName = CARTOUCHE_FPS_COUNTER_NAME

    static var home: URL {
        URL(filePath: NSHomeDirectory())
    }

    static var applicationSupport: URL {
        home.appending(path: "Library/Application Support")
    }

    // ~/Library/Application Support/Cartouche
    static var support: URL {
        applicationSupport.appending(path: supportDirName)
    }

    // ~/Library/Logs/Cartouche
    static var logs: URL {
        home.appending(path: "Library/Logs/\(supportDirName)")
    }

    static var bridge: URL { support.appending(path: "bridge") }
    static var runners: URL { support.appending(path: "runners") }
    static var backups: URL { support.appending(path: "backups") }
    static var launchers: URL { support.appending(path: "launchers") }

    static var signatures: URL {
        support.appending(path: "signatures/macos.arm64")
    }

    static var fonts: URL { support.appending(path: "fonts") }
    static var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
    static var iconmaker: URL { support.appending(path: "iconmaker") }
    static var appinfo: URL { support.appending(path: "appinfo") }
    // The frame counter the run script injects, and the sessions it records (P8)
    static var fpsCounter: URL { support.appending(path: fpsCounterName) }
    static var performance: URL { support.appending(path: CARTOUCHE_PERFORMANCE_DIR) }

    static var packageDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/valve-packages")
    }

    static var winetricksDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/winetricks")
    }

    static var deployedVersion: URL { support.appending(path: "dylib.version") }

    // The console session on record while a game runs; a killed Cartouche
    // reads it at the next launch to pick the session back up or count it
    static var consoleSession: URL { support.appending(path: "console-session.json") }

    // The socket the bundled cartouche-mcp helper connects to (P11); the agent
    // server binds it while Settings > Agents is on.
    static var agentSocket: URL { support.appending(path: CARTOUCHE_AGENT_SOCKET) }

    // Read by the dylib at Steam launch, in np_compat_load_tool_list.
    static var toolList: URL { support.appending(path: "tools") }
    // Read with it, one tool per runner and graphics backend pair (P3)
    static var backendToolList: URL { support.appending(path: CARTOUCHE_BACKEND_TOOL_LIST) }
    static var compatRequests: URL { support.appending(path: CARTOUCHE_COMPAT_REQUESTS) }
    static var backends: URL { support.appending(path: CARTOUCHE_BACKENDS_DIR) }
    static var setups: URL { support.appending(path: CARTOUCHE_SETUPS_DIR) }

    static func runnerRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: "crossover-\(build)")
    }

    static func crossOverRoot(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/SharedSupport/CrossOver")
    }

    static func clonedRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runnerRoot(forBuild: build, runners: runners).appending(path: "CrossOver")
    }

    static func prefixTemplates(forBuild build: String, in library: SteamLibrary) -> [URL] {
        CompatTool.Flavor.allCases.map { prefixTemplate(forBuild: build, flavor: $0, in: library) }
    }

    static func prefixTemplate(forBuild build: String, flavor: CompatTool.Flavor, in library: SteamLibrary) -> URL {
        library.compatdata.appending(path: prefixTemplateFolder).appending(path: "crossover-\(build)-\(flavor.unixDir)")
    }

    static let prefixTemplateFolder = "\(steamPrefix)-template"
    static let bridgeCacheFolder = "bridge"

    enum Steam {
        static let defaultApp = URL(filePath: "/Applications/Steam.app")
        static let appPathKey = "steamAppPath"

        static var app: URL {
            UserDefaults.standard.string(forKey: appPathKey).map { URL(filePath: $0) } ?? defaultApp
        }
        static func isUnreachable(_ bundle: URL = app) -> Bool {
            !FileManager.default.fileExists(atPath: bundle.deletingLastPathComponent().path(percentEncoded: false))
        }
        static var infoPlist: URL { infoPlist(inBundle: app) }
        static var executable: URL { app.appending(path: "Contents/MacOS/steam_osx") }
        static var deployedDylib: URL { deployedDylib(inBundle: app) }

        static func infoPlist(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/Info.plist")
        }

        static func deployedDylib(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/MacOS/\(dylibName)")
        }

        static var userData: URL {
            SupportPaths.applicationSupport.appending(path: "Steam")
        }

        static var configFile: URL { userData.appending(path: "steam.cfg") }

        static var innerApp: URL { userData.appending(path: "Steam.AppBundle/Steam") }
        static var innerInfoPlist: URL { innerApp.appending(path: "Contents/Info.plist") }

        static var innerClient: URL { innerApp.appending(path: "Contents/MacOS") }

        static var innerConfigFile: URL { innerClient.appending(path: "steam.cfg") }
        static var legacyCompat: URL { innerClient.appending(path: "legacycompat") }

        static var compatTools: URL { userData.appending(path: "compatibilitytools.d") }

        static func cartoucheTools(in directory: URL = compatTools) -> [URL] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            return entries.filter { $0.lastPathComponent.hasPrefix(SupportPaths.toolPrefix) }
        }

        static var libraryFoldersVDF: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    }
}
