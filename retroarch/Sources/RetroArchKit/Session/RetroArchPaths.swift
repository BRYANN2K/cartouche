import Foundation

// Every folder and file Cartouche keeps for RetroArch, under one root that the
// app owns. None of them is the user's own RetroArch folder.
public struct RetroArchPaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var cores: URL { folder("cores") }
    public var coreInfo: URL { folder("info") }
    public var bios: URL { folder("system") }
    public var saves: URL { folder("saves") }
    public var states: URL { folder("states") }
    public var screenshots: URL { folder("screenshots") }
    public var downloads: URL { folder("downloads") }
    public var builds: URL { folder("builds") }
    public var logs: URL { folder("logs") }
    public var playlists: URL { folder("playlists") }
    public var recordings: URL { folder("recordings") }
    public var thumbnails: URL { folder("thumbnails") }
    public var cache: URL { folder("cache") }
    // RetroArch's menu config folder: overrides, remaps, core options
    public var menuConfig: URL { folder("config") }
    // Where RetroArch unpacks the assets it carries
    public var bundle: URL { folder("bundle") }
    // The libretro database, one .rdb per console
    public var database: URL { folder("database") }
    // Cartouche's own shader presets for the Look choice
    public var shaders: URL { folder("shaders") }
    // RetroArch's home, HOME and CFFIXED_USER_HOME: what it makes under ~
    // (~/Documents/RetroArch, ~/Library/Application Support/RetroArch) stays here
    public var home: URL { folder("home") }

    // The included RetroArch's own retroarch.cfg, passed with -c so that the
    // user's file is never read or written
    public var baseConfig: URL { root.appending(path: "retroarch.cfg") }
    // Passed with --appendconfig, rewritten before each launch
    public var appendConfig: URL { root.appending(path: "cartouche.cfg") }
    // Size and hash of each core as first downloaded
    public var coreRecords: URL { root.appending(path: "cores.json") }
    public var consoles: URL { root.appending(path: "consoles.json") }
    public var settings: URL { root.appending(path: "settings.json") }

    private func folder(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }

    func create() throws {
        for folder in [
            cores, coreInfo, bios, saves, states, screenshots, downloads, logs, playlists, recordings,
            thumbnails, cache, menuConfig, bundle, home,
        ] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
