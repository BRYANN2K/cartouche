import Foundation
import RetroArchKit
import Synchronization
import Testing

@testable import NotProtonApp

// The QA harness (qa/) leans on CARTOUCHE_QA_BASE_URL: every remote base address
// must re-point to it, and nothing may change without it.
@Suite("QA environment", .serialized)
struct QAEnvironmentTests {

    // The variable belongs to the process: save and restore it so a QA-mode
    // exercise cannot leak into another test.
    private func withEnv<R>(_ value: String?, _ body: () throws -> R) rethrows -> R {
        let key = QAEnvironment.envKey
        let saved = getenv(key).map { String(cString: $0) }
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        return try body()
    }

    private func withEnv<R>(_ value: String?, _ body: () async throws -> R) async rethrows -> R {
        let key = QAEnvironment.envKey
        let saved = getenv(key).map { String(cString: $0) }
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        return try await body()
    }

    @Test("Without the variable every production address is untouched")
    func inactiveByDefault() {
        withEnv(nil) {
            #expect(QAEnvironment.base == nil)
            #expect(!QAEnvironment.isActive)
            #expect(MacGamingDBClient.api.absoluteString == "https://macgamingdb.app/api/rest/games/")
            #expect(SteamSetup.valveInstaller.absoluteString == "https://cdn.fastly.steamstatic.com/client/installer/steam.dmg")
            #expect(CoverStore.cdn(730, .cover).absoluteString
                == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/730/library_600x900.jpg")
            #expect(GameCover.steam(appID: 730)?.absoluteString
                == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/730/library_600x900.jpg")
            #expect(CoreSource.qa == .buildbot)
            #expect(DatabaseSource.qa == .libretro)
            #expect(CoverStore().consoleThumbnails.base.absoluteString == "https://thumbnails.libretro.com/")
            #expect(QAEnvironment.url(OfficialRelease.stable).absoluteString == "https://buildbot.libretro.com/stable/")
        }
    }

    @Test("A release-configured QAEnvironment ignores the variable")
    func releaseIgnoresTheVariable() async {
        await withEnv("http://127.0.0.1:8890") { () async -> Void in
            // The release configuration never honours the value, however it is
            // spelled: with supported == false the base stays nil.
            #expect(QAEnvironment.base(from: "http://127.0.0.1:8890", supported: false) == nil)
            #expect(QAEnvironment.base(from: "https://qa.example/x", supported: false) == nil)
            #if DEBUG
            // This build is the QA configuration: the variable is honoured.
            #expect(QAEnvironment.isSupported)
            #expect(QAEnvironment.base != nil)
            #else
            // A release build never reads the variable at all.
            #expect(!QAEnvironment.isSupported)
            #expect(QAEnvironment.base == nil)
            #expect(!QAEnvironment.isActive)
            let prod = URL(string: "https://macgamingdb.app/x")!
            #expect(QAEnvironment.url(prod) == prod)
            StubServer.requests.withLock { $0 = [] }
            let pins = await QAEnvironment.extraHashes(session: StubServer.session)
            #expect(pins.isEmpty)
            #expect(StubServer.requests.withLock { $0 }.isEmpty)
            #endif
        }
    }

    @Test("With the variable every fetched endpoint keeps its path on the QA server")
    func rewritesWhenActive() {
        withEnv("http://127.0.0.1:8890") {
            let base = "http://127.0.0.1:8890"
            #expect(QAEnvironment.base?.absoluteString == base)
            #expect(QAEnvironment.isActive)
            #expect(MacGamingDBClient.api.absoluteString == "\(base)/api/rest/games/")
            #expect(SteamSetup.valveInstaller.absoluteString == "\(base)/client/installer/steam.dmg")
            #expect(CoverStore.cdn(730, .hero).absoluteString
                == "\(base)/store_item_assets/steam/apps/730/library_hero.jpg")
            #expect(GameCover.steam(appID: 730)?.absoluteString
                == "\(base)/store_item_assets/steam/apps/730/library_600x900.jpg")
            #expect(CoreSource.qa.cores.absoluteString == "\(base)/nightly/apple/osx/arm64/latest/")
            #expect(CoreSource.qa.info.absoluteString == "\(base)/assets/frontend/info.zip")
            #expect(DatabaseSource.qa.base.absoluteString == "\(base)/libretro/libretro-database/master/rdb/")
            #expect(CoverStore().consoleThumbnails.base.absoluteString == "\(base)/")
            #expect(QAEnvironment.url(OfficialRelease.stable).absoluteString == "\(base)/stable/")
            // The Sparkle appcast keeps its release path, so the compat feed and
            // the runner manifest feed derive to mock addresses
            #expect(QAEnvironment.url("https://github.com/BRYANN2K/cartouche/releases/latest/download/appcast.xml")?.absoluteString
                == "\(base)/BRYANN2K/cartouche/releases/latest/download/appcast.xml")
        }
    }

    @Test("The rewrite keeps path, query and escapes, drops credentials, honours a base path")
    func keepsPathAndQuery() {
        withEnv("http://qa.local:1234/prefix") {
            #expect(QAEnvironment.url(URL(string:
                "https://user:secret@thumbnails.libretro.com/Nintendo%20-%20Game%20Boy/Named_Boxarts/x.png?size=1")!
            ).absoluteString == "http://qa.local:1234/prefix/Nintendo%20-%20Game%20Boy/Named_Boxarts/x.png?size=1")
        }
    }

    @Test("Only http(s) bases count, and non-http URLs are never re-pointed")
    func schemesStaySafe() {
        let prod = URL(string: "https://macgamingdb.app/x")!
        for garbage in ["", "not a url", "ftp://qa.local", "file:///tmp"] {
            withEnv(garbage) {
                #expect(QAEnvironment.base == nil, "'\(garbage)' must not switch QA mode on")
                #expect(QAEnvironment.url(prod) == prod)
            }
        }
        withEnv("http://127.0.0.1:1") {
            let file = URL(filePath: "/tmp/x.zip")
            #expect(QAEnvironment.url(file) == file)
            #expect(QAEnvironment.url(URL(string: "steam://rungameid/730")!) == URL(string: "steam://rungameid/730")!)
        }
    }

    @Test("In QA mode the Steam fallback stays inside the QA home")
    func qaSteamFallback() {
        withEnv(nil) {
            #expect(SupportPaths.Steam.defaultApp == URL(filePath: "/Applications/Steam.app"))
        }
        withEnv("http://127.0.0.1:8890") {
            let fallback = SupportPaths.Steam.defaultApp
            #expect(fallback.path(percentEncoded: false) != "/Applications/Steam.app")
            #expect(fallback.path(percentEncoded: false)
                .hasPrefix(SupportPaths.home.path(percentEncoded: false)))
        }
    }

    @Test("Store sign-ins use their own Keychain service in QA mode")
    func qaKeychainService() {
        withEnv(nil) {
            #expect(KeychainVault.service == "dev.bryann2k.cartouche.store")
            #expect(KeychainVault().service == "dev.bryann2k.cartouche.store")
        }
        withEnv("http://127.0.0.1:8890") {
            #expect(KeychainVault.service == "dev.bryann2k.cartouche.store.qa")
            #expect(KeychainVault().service == "dev.bryann2k.cartouche.store.qa")
        }
    }

    @Test("__pins.json yields its sha256s in either shape")
    func pinsParse() throws {
        let a = Digest.sha256(of: Data("a".utf8))
        let b = Digest.sha256(of: Data("b".utf8))
        #expect(QAEnvironment.hashes(in: Data(#"["\#(a)", "\#(b)"]"#.utf8)) == [a, b])
        #expect(QAEnvironment.hashes(in: Data(#"{"wine.tar.xz": "\#(a)", "nested": {"x": "\#(b)"}}"#.utf8)) == [a, b])
        #expect(QAEnvironment.hashes(in: Data("not json".utf8)).isEmpty)
        // Only real lowercase sha256s count
        #expect(QAEnvironment.hashes(in: Data(#"{"hash": "\#(a.uppercased())", "short": "1234"}"#.utf8)).isEmpty)
    }

    @Test("extraHashes stays empty without the variable — the pins file is not even asked for")
    func extraHashesEmptyWithoutQA() async {
        let pins = await withEnv(nil) { () async -> Set<String> in
            StubServer.requests.withLock { $0 = [] }
            return await QAEnvironment.extraHashes(session: StubServer.session)
        }
        #expect(pins.isEmpty)
        #expect(StubServer.requests.withLock { $0 }.isEmpty)
    }

    @Test("extraHashes reads the server's __pins.json")
    func extraHashesFromServer() async throws {
        let sha = Digest.sha256(of: Data("fixture".utf8))
        StubServer.serve("/" + QAEnvironment.pinsFile, body: Data(#"{"package.tar": "\#(sha)"}"#.utf8))
        let pins = await withEnv("http://mock.qa") {
            await QAEnvironment.extraHashes(session: StubServer.session)
        }
        #expect(pins == [sha])
    }

    @Test("A pinned download accepts a hash the QA server lists, fetched from the QA server")
    func pinnedDownloadUsesQA() async throws {
        let work = try scratchDirectory("qa")
        defer { try? FileManager.default.removeItem(at: work) }
        let body = Data("synthetic qa archive".utf8)
        let sha = Digest.sha256(of: body)
        StubServer.requests.withLock { $0 = [] }
        StubServer.serve("/" + QAEnvironment.pinsFile, body: Data(#"["\#(sha)"]"#.utf8))
        StubServer.serve("/package.tar", body: body)

        let got = try await withEnv("http://mock.qa") {
            try await PinnedDownload.obtain(
                file: "package.tar", sha256: String(repeating: "0", count: 64),
                bases: [URL(string: "https://real-cdn.invalid/")!],
                into: work.appending(path: "downloads"), step: "test",
                session: StubServer.session)
        }

        #expect(try Data(contentsOf: got) == body)
        let asked = StubServer.requests.withLock { $0 }
        #expect(asked.contains("mock.qa/" + QAEnvironment.pinsFile))
        #expect(asked.contains("mock.qa/package.tar"))
        #expect(!asked.contains { $0.hasPrefix("real-cdn.invalid") })
    }

    @Test("A hash the QA server does not list is still refused in QA mode")
    func pinsDoNotBlanketAccept() async throws {
        let work = try scratchDirectory("qa")
        defer { try? FileManager.default.removeItem(at: work) }
        let other = Digest.sha256(of: Data("other".utf8))
        StubServer.serve("/" + QAEnvironment.pinsFile, body: Data(#"["\#(other)"]"#.utf8))
        StubServer.serve("/package.tar", body: Data("synthetic qa archive".utf8))

        await #expect(throws: StepFailure.self) {
            try await withEnv("http://mock.qa") {
                try await PinnedDownload.obtain(
                    file: "package.tar", sha256: String(repeating: "0", count: 64),
                    bases: [URL(string: "https://real-cdn.invalid/")!],
                    into: work.appending(path: "downloads"), step: "test",
                    session: StubServer.session)
            }
        }
    }

    @Test("A backend install accepts a QA-pinned archive end to end")
    func backendInstallUsesQA() async throws {
        let work = try scratchDirectory("qa")
        defer { try? FileManager.default.removeItem(at: work) }

        // An archive in the DXMT layout, served by the mock
        let tree = work.appending(path: "tree")
        for path in ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll",
                     "x86_64-windows/winemetal.dll", "x86_64-unix/winemetal.so"] {
            let file = tree.appending(path: "dxmt-v0.80").appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ qa".utf8).write(to: file)
        }
        let tarball = work.appending(path: "dxmt.tar.gz")
        try Shell.check("/usr/bin/tar",
            ["-czf", tarball.path(percentEncoded: false), "-C", tree.path(percentEncoded: false), "dxmt-v0.80"])
        let bytes = try Data(contentsOf: tarball)
        let sha = Digest.sha256(of: bytes)
        StubServer.serve("/" + QAEnvironment.pinsFile, body: Data(#"{"dxmt.tar.gz": "\#(sha)"}"#.utf8))
        StubServer.serve("/dxmt/dxmt.tar.gz", body: bytes)

        let shipped = try #require(BackendManifest.bundled().pin(.dxmt))
        let pin = BackendManifest.Pin(
            backend: .dxmt, name: shipped.name, version: shipped.version, license: shipped.license,
            url: URL(string: "https://github.com/dxmt/dxmt.tar.gz")!,
            size: 999_999, sha256: String(repeating: "f", count: 64), files: shipped.files)

        let backends = work.appending(path: "backends")
        let downloads = work.appending(path: "downloads")
        let receipt = try await withEnv("http://mock.qa") {
            try await BackendInstaller.install(
                pin, backends: backends, downloads: downloads, session: StubServer.session)
        }

        // The receipt carries the pin, and every deployed file matches it
        #expect(receipt.archiveSHA256 == pin.sha256)
        #expect(receipt.version == shipped.version)
        let deployed = BackendInstaller.folder(for: .dxmt, in: backends)
        #expect(receipt.files.allSatisfy { path, hash in
            Digest.sha256IfPresent(deployed.appending(path: path)) == hash
        })
    }

    // https literals that intentionally stay unwrapped: display-only links
    // (shown or opened by the user, never fetched), the User-Agent contact,
    // package defaults the app overrides at injection points (CoreSource.qa,
    // DatabaseSource.qa, OfficialRelease's base, Thumbnails.base), and Info.plist's
    // SUFeedURL — Sparkle never runs in a QA build, so nothing fetches it — and
    // CartoucheRunnerManifestURL, which RunnerManifest.feed passes through QAEnvironment.url.
    // A fetched endpoint must instead sit inside
    // QAEnvironment.url(...) on its own line (the run script uses the variable).
    private static let allowedLiterals: [String: [String]] = [
        "app/Sources/NotProtonApp/Support/Attribution.swift": [
            "https://cartouche.bryann2k.dev", "https://github.com/NotProtonNot/NotProton",
        ],
        "app/Sources/NotProtonApp/Compatibility/CompatibilityCredits.swift": ["https://macgamingdb.app"],
        "app/Sources/NotProtonApp/Compatibility/MacGamingDB.swift": ["https://cartouche.bryann2k.dev"],
        "app/Sources/NotProtonApp/Runners/PortingToolkitSource.swift": ["https://developer.apple.com"],
        "app/Info.plist": [
            "https://github.com/BRYANN2K/cartouche/",
            "https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/",
        ],
        "retroarch/Sources/RetroArchKit/Settings/ConsolesSettingsView.swift": ["https://github.com/libretro/RetroArch"],
        "retroarch/Sources/RetroArchKit/Identify/ContentDatabase.swift": ["https://raw.githubusercontent.com/libretro/"],
        "retroarch/Sources/RetroArchKit/Library/Thumbnails.swift": ["https://thumbnails.libretro.com/"],
        "retroarch/Sources/RetroArchKit/Builds/OfficialRelease.swift": ["https://buildbot.libretro.com/stable/"],
        "retroarch/Sources/RetroArchKit/Cores/CoreManager.swift": ["https://buildbot.libretro.com/"],
    ]

    @Test("No hard-coded https endpoint bypasses QAEnvironment.url")
    func noLiteralBypassesHelper() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var violations: [String] = []
        for root in ["app/Sources", "retroarch/Sources", "installer/Sources"] {
            let dir = repo.appending(path: root)
            guard let entries = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in entries where file.pathExtension == "swift" {
                violations += try check(file, repo: repo)
            }
        }
        for extra in ["app/Info.plist", "dylib/feats/compat_run.sh"] {
            violations += try check(repo.appending(path: extra), repo: repo)
        }
        if !violations.isEmpty {
            Issue.record(Comment(rawValue:
                "https endpoints not routed through QAEnvironment.url — route them, or exempt them in allowedLiterals with the reason:\n"
                    + violations.joined(separator: "\n")))
        }
        #expect(violations.isEmpty)
    }

    private func check(_ file: URL, repo: URL) throws -> [String] {
        let root = repo.path(percentEncoded: false)
        let path = file.path(percentEncoded: false)
        guard path.hasPrefix(root + "/") else { return [] }
        let relative = String(path.dropFirst(root.count + 1))
        let allowed = Self.allowedLiterals[relative] ?? []
        var violations: [String] = []
        for (index, line) in try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: .newlines).enumerated()
        where line.contains("https://")
            && !line.contains("QAEnvironment.url") && !line.contains("CARTOUCHE_QA_BASE_URL") {
            for match in Self.literals(in: line) where !allowed.contains(where: { match.hasPrefix($0) }) {
                violations.append("\(relative):\(index + 1): \(match)")
            }
        }
        return violations
    }

    private static func literals(in line: String) -> [String] {
        var found: [String] = []
        var rest = line[...]
        while let at = rest.range(of: "https://") {
            let tail = rest[at.lowerBound...]
            let end = tail.firstIndex(where: { " \t\"'()[]<>,;\\".contains($0) }) ?? tail.endIndex
            found.append(String(tail[..<end]))
            rest = tail[end...]
        }
        return found
    }
}

// Answers anything on *.qa hosts: paths registered with serve() get their bytes,
// anything else a 404. Requests are recorded as host+path.
private final class StubServer: URLProtocol, @unchecked Sendable {
    static let files = Mutex<[String: Data]>([:])
    static let requests = Mutex<[String]>([])

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    static func serve(_ path: String, body: Data) {
        files.withLock { $0[path] = body }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".qa") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestPath = request.url?.path(percentEncoded: false) ?? ""
        Self.requests.withLock { $0.append((request.url?.host ?? "") + requestPath) }
        let body = Self.files.withLock { $0[requestPath] }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
