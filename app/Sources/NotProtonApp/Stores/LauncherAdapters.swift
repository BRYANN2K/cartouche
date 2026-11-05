// Ubisoft Connect and the EA app as stores: the launcher lives in its own prefix, owns the
// session, and is driven through its protocol URIs (uplay://, origin2://). Games share that
// prefix through a symlink — the launcher itself manages their install. Ubisoft's library
// comes from the local cache after the user signs in inside the launcher; EA's from its
// private owned-games API, token in the vault only. StoreCenter.publish pushes them into
// the library like the other stores.

import AppKit
import Foundation
import InstallerKit

// What a launcher-backed store hands the library: the launcher itself, driven by URI.
struct LauncherBackedStore: Sendable {
    let folders: StoreFolders
    let secrets: StoreSecrets
    var wine: @Sendable () async throws -> WineRunner
    // Resolved by the center — the backend a store game's own launch would pick (B11)
    var backend: @Sendable () async -> GraphicsBackend? = { nil }
    var run: any LauncherRun
    // Tests see what the workspace would have opened.
    var openWeb: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var base: [String: String] = SetupEnvironment.base
    // EA's pre-launch check — the LSX port probe; fixtures stub it away.
    var eaPreflight: @Sendable () async throws -> Void = EAPreflight.checkLSX
    // The beat of every launcher-state wait below (install/uninstall confirmation);
    // fixtures stub it to a tick so tests do not sleep real seconds.
    var poll: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }

    func launcher(_ store: GameSource) -> StoreLauncher {
        var launcher = StoreLauncher(store: store, folder: folders.launcher(store), wine: wine, run: run, base: base)
        launcher.backend = backend
        if store == .ea { launcher.preflight = eaPreflight }
        return launcher
    }

    // The game's folder links its pfx at the launcher's: the game lives where the launcher puts it.
    func linkPrefix(of folder: URL, to store: GameSource) throws {
        let link = folder.appending(path: "pfx")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: launcher(store).prefix)
    }
}

// Ubisoft Connect. The session is whatever the launcher cached after the user's own
// sign-in; Cartouche only reads it.
struct UbisoftAdapter: StoreAdapter {
    var store: GameSource { .ubisoft }

    var backing: LauncherBackedStore
    var cache: @Sendable (URL) throws -> UbisoftCache = UbisoftLocalCache.read
    var now: @Sendable () -> Date = { Date() }
    // How stale the cache can be before the session is asked for again — the launcher's
    // own expiry is unverified; a week matches the other stores' token windows.
    var sessionWindow: TimeInterval = 7 * 24 * 3600

    var launcher: StoreLauncher { backing.launcher(store) }
    // The web opener, for tests.
    var openWeb: @MainActor (URL) -> Void {
        get { backing.openWeb }
        set { backing.openWeb = newValue }
    }
    var capabilities: StoreCapabilities {
        StoreCapabilities(client: "Ubisoft Connect", cloudSaves: false, online: .dependsOnGame)
    }

    // The account id the launcher signed in as — nil until the cache exists. The sign-in
    // sheet polls it while the user types in the launcher.
    func detectedSession() async -> String? {
        try? cache(launcher.prefix).userID
    }

    // Sign-in happens inside the real launcher window, never a WebView: the sheet only
    // prompts for it, and the session lands when the cache names an account.
    func signInPage() async throws -> SignInPage {
        _ = try await launcher.open()
        return SignInPage(url: URL(string: LauncherLinks.open(store))!, codePage: nil, viaLauncher: true)
    }

    // The sign-in ends when the cache names an account, not when a URL does.
    func code(at url: URL, pageText: String?) -> String? { nil }

    func finishSignIn(code: String) async throws -> String {
        let cache = try self.cache(launcher.prefix)
        guard let user = cache.userID, user == code else {
            throw StoreError.failed(String(localized: "Ubisoft Connect has no sign-in yet. Sign in inside the launcher, then come back."))
        }
        try await remember(account: user, cache: cache)
        return user
    }

    private func remember(account: String, cache: UbisoftCache) async throws {
        let stamp = UbisoftStamp(modified: cache.ownershipModified ?? now(), account: account)
        try await backing.secrets.write(files: ["session.json": stamp.data()], account: account, for: store)
    }

    // The launcher's cached account file goes: the session it kept ends with it, and the
    // next poll no longer sees an account to adopt back.
    func signOut() async throws {
        if let account = await detectedSession() {
            UbisoftLocalCache.forget(prefix: launcher.prefix, account: account)
        }
    }

    // The secret's stamp is the cache's own write time; past the window the session is asked for again.
    func isExpired(_ secret: StoreSecret, now: Date) -> Bool {
        guard let stamp = secret.files["session.json"].flatMap(UbisoftStamp.read) else { return false }
        return now.timeIntervalSince(stamp.modified) > sessionWindow
    }

    func library() async throws -> [StoreGame] {
        let cache = try self.cache(launcher.prefix)
        let sections = launcher.registry()
        var handled: Set<String> = []
        var games: [StoreGame] = []
        for owned in cache.owned where cache.visibleIDs.contains(owned.productID) {
            // Editions of one title share its space: one card, the installed product first
            let key = owned.spaceID ?? "product-\(owned.productID)"
            guard handled.insert(key).inserted else { continue }
            let pick = cache.owned.lazy
                .filter { cache.visibleIDs.contains($0.productID) && ($0.spaceID ?? "product-\($0.productID)") == key }
                .min {
                    let first = Self.has(sections, Self.uninstallEntry(String($0.productID)))
                    let second = Self.has(sections, Self.uninstallEntry(String($1.productID)))
                    return first != second ? first : $0.productID < $1.productID
                } ?? owned
            let config = cache.configs[pick.productID]
            let space = pick.spaceID.flatMap { cache.spaces[$0] }
            // The space's tile is wide: it is never the card's `art` — it goes to the
            // panel and stays the cover chain's last resort via `artFallback`.
            var game = StoreGame(id: String(pick.productID),
                                 title: config?.title ?? pick.spaceID.flatMap { cache.titles[$0] } ?? space?.name
                                    ?? pick.gameCode ?? "Ubisoft game \(pick.productID)",
                                 art: config?.art ?? space?.art,
                                 header: config?.header ?? space?.header ?? pick.spaceID.flatMap(UbisoftLocalCache.tile))
            game.artFallback = pick.spaceID.flatMap(UbisoftLocalCache.tile)
            game.installPath = Self.settledInstall(of: game.id, in: sections, prefix: launcher.prefix)
            games.append(game)
        }
        // A sealed .vdat cache lists nothing owned; the launcher's own registry still
        // names the games it installed. Dropped editions keep their ids known so their
        // entries do not come back as second cards.
        let known = Set(games.map(\.id) + cache.owned.map { String($0.productID) })
        games += Self.installedNames(in: sections)
            .filter { !known.contains($0.key) }
            .sorted { (Int($0.key) ?? .max, $0.key) < (Int($1.key) ?? .max, $1.key) }
            .map { id, name in
                var game = StoreGame(id: id, title: name.isEmpty ? "Ubisoft game \(id)" : name)
                game.installPath = Self.settledInstall(of: id, in: sections, prefix: launcher.prefix)
                return game
            }
        return games
    }

    // The launcher's own registry is the truth of an install: `Launcher\Installs\<id>`
    // while it fetches, `Uninstall\Uplay Install <id>` once it is really there. Done
    // means the entry exists AND the folder holds a settled size — never just the URI.
    static let installsKey = #"Software\Wow6432Node\Ubisoft\Launcher\Installs"#
    static let uninstallKey = #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#
    static func uninstallEntry(_ id: String) -> String { uninstallKey + "\\Uplay Install \(id)" }

    // How long the user can take clicking Install inside the launcher before we give up waiting for it.
    var installPickup: TimeInterval = 10 * 60

    static func installPath(of id: String, in sections: [String: [String: String]]) -> String? {
        if let location = WineRegistry.values(in: sections, under: uninstallEntry(id))?["installlocation"] { return location }
        return WineRegistry.values(in: sections, under: installsKey + "\\" + id)?["installdir"]
    }

    // A really-there install: the Uninstall entry exists and its folder is on disk —
    // Installs\<id> alone is still fetching. What the launcher's page calls installed.
    static func settledInstall(of id: String, in sections: [String: [String: String]], prefix: URL) -> URL? {
        guard has(sections, uninstallEntry(id)),
              let path = installPath(of: id, in: sections),
              let install = WinePath.unix(path, prefix: prefix),
              LauncherFolder.folderBytes(install) >= 0 else { return nil }
        return install
    }

    static func has(_ sections: [String: [String: String]], _ key: String) -> Bool {
        WineRegistry.values(in: sections, under: key) != nil
    }

    // The installs the registry names: Installs\<id> while it fetches and
    // Uninstall\Uplay Install <id> once settled — the DisplayName where one exists.
    static func installedNames(in sections: [String: [String: String]]) -> [String: String] {
        var names: [String: String] = [:]
        let pending = installsKey.uppercased() + "\\"
        let settled = (uninstallKey + "\\Uplay Install ").uppercased()
        for (name, values) in sections {
            let id = name.count > pending.count && name.uppercased().hasPrefix(pending) ? String(name.dropFirst(pending.count))
                : name.count > settled.count && name.uppercased().hasPrefix(settled) ? String(name.dropFirst(settled.count))
                : nil
            if let id, names[id]?.isEmpty != false { names[id] = values["displayname"] ?? "" }
        }
        return names
    }

    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        try backing.linkPrefix(of: base.deletingLastPathComponent(), to: store)
        _ = try await launcher.open(LauncherLinks.install(store, id: game.id))
        var started = false
        var settled: Int64? = nil
        let pickup = now().addingTimeInterval(installPickup)
        while true {
            try Task.checkCancellation()
            let sections = launcher.registry()
            let pending = Self.has(sections, Self.installsKey + "\\" + game.id)
            let confirmed = Self.has(sections, Self.uninstallEntry(game.id))
            started = started || pending || confirmed
            guard let path = Self.installPath(of: game.id, in: sections),
                  let install = WinePath.unix(path, prefix: launcher.prefix) else {
                // The Uninstall entry landed without any path to the game: report it, not silence.
                if confirmed && now() >= pickup {
                    throw StoreError.failed(String(localized: "Ubisoft Connect did not report where \(game.title) went."))
                }
                // The Installs entry vanished without the game ever landing: the
                // launcher aborted the install, or the user cancelled it there.
                if started && !pending && !confirmed {
                    throw StoreError.failed(String(localized: "Ubisoft Connect stopped installing \(game.title) before it finished."))
                }
                if !started && now() >= pickup {
                    throw StoreError.failed(String(localized: "Ubisoft Connect did not start installing \(game.title) — start it from the launcher’s own page."))
                }
                try await backing.poll()
                continue
            }
            let bytes = LauncherFolder.folderBytes(install)
            // The registry says the game is there but the folder never appeared: dead too.
            if bytes < 0 && now() >= pickup {
                throw StoreError.failed(String(localized: "Ubisoft Connect reported \(game.title) but its folder never landed."))
            }
            if confirmed && bytes >= 0 && bytes == settled {
                progress(1)
                return StoreInstall(path: install)
            }
            settled = bytes >= 0 ? bytes : nil
            if bytes > 0, let total = game.diskBytes, total > 0 { progress(min(0.99, Double(bytes) / Double(total))) }
            try await backing.poll()
        }
    }

    private func uplayID(_ id: String, prefix: URL) async throws -> String {
        if let owned = try? cache(prefix).owned.first(where: { String($0.productID) == id }), let uplayID = owned.uplayID {
            return String(uplayID)
        }
        return id
    }

    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch {
        let uplay = try await uplayID(id, prefix: launcher.prefix)
        return StoreLaunch(executable: launcher.executable,
                           arguments: [LauncherLinks.launch(store, id: uplay)] + launcher.launchArguments,
                           workingDirectory: launcher.executable.deletingLastPathComponent())
    }

    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        throw StoreError.failed(String(localized: "Ubisoft Connect updates its games itself — open the game’s page in the launcher."))
    }

    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw StoreError.failed(String(localized: "Ubisoft Connect verifies its games itself — open the game’s page in the launcher."))
    }

    // uplay://uninstall opens the launcher's own removal; only when every trace is gone —
    // Uninstall entry, Installs entry and the folder — does the record come off. If the
    // user says no there, nothing moves and cancelling the job keeps everything.
    func uninstall(_ id: String, install: StoreInstall) async throws {
        let uplay = try await uplayID(id, prefix: launcher.prefix)
        _ = try await launcher.open(LauncherLinks.uninstall(store, id: uplay))
        while true {
            try Task.checkCancellation()
            let sections = launcher.registry()
            let registryGone = !Self.has(sections, Self.uninstallEntry(id)) && !Self.has(sections, Self.installsKey + "\\" + id)
            let folderGone = LauncherFolder.folderBytes(install.path) < 0
            if registryGone && folderGone { return }
            try await backing.poll()
        }
    }

    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall) {
        throw StoreError.failed(String(localized: "Add the game to Ubisoft Connect first, then let it manage the install."))
    }

    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation] { [] }
    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String] { stamps }

    // The launcher itself, and a game's own page in it — the store button's two faces.
    @discardableResult
    func openLauncher() async throws -> any LauncherProcess { try await launcher.open() }

    func openStorePage(_ game: StoreGame?) async throws {
        guard let game else { await backing.openWeb(LauncherLinks.storePage(store)); return }
        let uplay = try await uplayID(game.id, prefix: launcher.prefix)
        _ = try await launcher.open(LauncherLinks.gamePage(store, launchID: uplay))
    }
}

// The session stamp the vault holds for Ubisoft: the cache's own write time.
struct UbisoftStamp: Codable, Equatable, Sendable {
    var modified: Date
    var account: String

    func data() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    static func read(_ data: Data) -> UbisoftStamp? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UbisoftStamp.self, from: data)
    }
}

// The EA app. Sign-in runs inside the launcher itself — its OAuth is PKCE ending on a
// qrc:// page only its CEF reaches (B7), so a WebView or loopback flow can't work —
// and the adopted session token is written to the vault, never to a file, a log or an
// argument. The owned-games API is private and unversioned — the accepted risk, recorded
// in the docs.
struct EAAdapter: StoreAdapter {
    var store: GameSource { .ea }

    // THE single switch for EA: on, it ships labelled Experimental. Off, it is in no list; `enabled`
    // defaults to it and every entry point is gated. Off since 2026-11-04: the launcher signs in and
    // lists the account's games, but its session is encrypted (ProgramData/EA Desktop/<hash>/IS) and
    // the token exchange needs EA's client secret, so Cartouche cannot list them (ea-lsx-auth.md).
    static let experimental = false
    var enabled: Bool = EAAdapter.experimental

    var backing: LauncherBackedStore
    var flow = EAAuthFlow()
    var api = EALibrary()
    var sessionProbe: @Sendable (URL, Date) -> EAToken? = EASessionProbe.token
    var now: @Sendable () -> Date = { Date() }

    static var unavailable: StoreError {
        .failed(String(localized: "The EA app is experimental in this build — its support is not enabled yet."))
    }

    var isAvailable: Bool { enabled }

    var launcher: StoreLauncher { backing.launcher(store) }
    var openWeb: @MainActor (URL) -> Void {
        get { backing.openWeb }
        set { backing.openWeb = newValue }
    }
    var capabilities: StoreCapabilities {
        StoreCapabilities(client: "EA app", cloudSaves: false, online: .dependsOnGame)
    }

    // Sign-in happens inside the real EA app (B7's launch recipe rides along): the sheet
    // only prompts for it, and the session lands when the prefix yields an adoptable token.
    func signInPage() async throws -> SignInPage {
        guard enabled else { throw Self.unavailable }
        _ = try await launcher.open()
        return SignInPage(url: URL(string: LauncherLinks.open(store))!, codePage: nil, viaLauncher: true)
    }

    // A live session the launcher left — what the sign-in watcher polls. Disabled, the
    // prefix is never even read.
    func detectedSession() async -> String? {
        guard enabled, sessionProbe(launcher.prefix, now()) != nil else { return nil }
        return Self.detected
    }

    // No URL hands over a code; the session file is the proof, not a redirect.
    func code(at url: URL, pageText: String?) -> String? { nil }

    // What detectedSession() reports — the account itself is named by the API at finish.
    static let detected = "ea-app"

    // The launcher's own Wine session, adopted: the probe's live token is named by the
    // API, written to the vault, and its plaintext files scrubbed. `code` is only the
    // watcher's marker — the session file is the real gate.
    func finishSignIn(code: String) async throws -> String {
        guard enabled else { throw Self.unavailable }
        guard var token = sessionProbe(launcher.prefix, now()) else {
            throw StoreError.failed(String(localized: "The EA app has no sign-in yet. Sign in inside the launcher, then come back."))
        }
        if token.expired(at: now()), let refreshed = try? await flow.refresh(token) { token = refreshed }
        let account = (try? await api.account(token)) ?? ""
        try await backing.secrets.write(files: ["token.json": token.json()], account: account, for: store)
        EASessionProbe.scrub(in: launcher.prefix)
        return account
    }

    // The adoption path, as a yes/no: nothing to adopt means the launcher is not signed in.
    func adoptLauncherSession() async throws -> Bool {
        guard enabled else { throw Self.unavailable }
        guard await detectedSession() != nil else { return false }
        _ = try await finishSignIn(code: Self.detected)
        return true
    }

    // The launcher's plaintext session files go too — nothing remains for a later probe
    // to adopt back, like signOut clearing Ubisoft's cached account.
    func signOut() async throws { EASessionProbe.scrub(in: launcher.prefix) }

    // Expired when both dates are past: a live access token or a live refresh window still counts.
    // Disabled, the token is never even opened.
    func isExpired(_ secret: StoreSecret, now: Date) -> Bool {
        guard enabled else { return false }
        guard let token = secret.files["token.json"].flatMap(EAToken.read) else { return false }
        return !token.live(at: now)
    }

    private func token() async throws -> EAToken {
        guard let token = try await backing.secrets.secret(store)?.files["token.json"].flatMap(EAToken.read) else {
            throw StoreError.notSignedIn
        }
        return token
    }

    private func save(_ token: EAToken) async throws {
        let account = try await backing.secrets.secret(store)?.account ?? ""
        try await backing.secrets.write(files: ["token.json": token.json()], account: account, for: store)
    }

    // The access token as it stands, or refreshed once and written back — the refresh only
    // rides when the saved one is stale.
    private func liveToken() async throws -> EAToken {
        var token = try await self.token()
        guard token.expired(at: now()) else { return token }
        token = try await flow.refresh(token)
        try await save(token)
        return token
    }

    // Disabled means no token read and no request — not even for a session already in the vault.
    func library() async throws -> [StoreGame] {
        guard enabled else { throw Self.unavailable }
        return try await api.games(liveToken())
    }

    // How long the user can take confirming inside the EA app before the wait gives up.
    var installPickup: TimeInterval = 10 * 60

    // Same contract as Ubisoft's: installerdata.xml names where the offer goes, and done
    // means the folder exists AND its size settled — the URI alone never finishes it.
    func install(_ game: StoreGame, base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        guard enabled else { throw Self.unavailable }
        try backing.linkPrefix(of: base.deletingLastPathComponent(), to: store)
        _ = try await launcher.open(LauncherLinks.install(store, id: game.id))
        var seen = false
        var settled: Int64? = nil
        let pickup = now().addingTimeInterval(installPickup)
        while true {
            try Task.checkCancellation()
            guard let path = EAInstallLocation.path(for: game.id, in: launcher.prefix),
                  let install = WinePath.unix(path, prefix: launcher.prefix) else {
                // A manifest that was there and vanished mid-wait: the launcher dropped the install.
                if seen {
                    throw StoreError.failed(String(localized: "The EA app stopped installing \(game.title) before it finished."))
                }
                if now() >= pickup {
                    throw StoreError.failed(String(localized: "The EA app did not start installing \(game.title) — start it from the launcher’s own page."))
                }
                try await backing.poll()
                continue
            }
            seen = true
            let bytes = LauncherFolder.folderBytes(install)
            if bytes < 0 && now() >= pickup {
                throw StoreError.failed(String(localized: "The EA app reported \(game.title) but its folder never landed."))
            }
            if bytes >= 0 && bytes == settled {
                progress(1)
                return StoreInstall(path: install)
            }
            settled = bytes >= 0 ? bytes : nil
            if bytes > 0, let total = game.diskBytes, total > 0 { progress(min(0.99, Double(bytes) / Double(total))) }
            try await backing.poll()
        }
    }

    func launch(_ id: String, install: StoreInstall, prefix: URL, offline: Bool) async throws -> StoreLaunch {
        guard enabled else { throw Self.unavailable }
        try await backing.eaPreflight()
        // The URI starts the same EADesktop.exe — B7's env (software Qt, drained wbemprox
        // trace) rides along; the play path's bounded log keeps its stderr really written.
        return StoreLaunch(executable: launcher.executable, arguments: [LauncherLinks.launch(store, id: id)],
                           workingDirectory: launcher.executable.deletingLastPathComponent(),
                           environment: launcher.launchEnvironment)
    }

    // EA's protocol has no uninstall or repair URI; the launcher's own UI does both.
    func uninstall(_ id: String, install: StoreInstall) async throws {
        guard enabled else { throw Self.unavailable }
        throw StoreError.failed(String(localized: "Uninstall the game from the EA app — its Manage page removes it."))
    }

    func update(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws -> StoreInstall {
        guard enabled else { throw Self.unavailable }
        throw StoreError.failed(String(localized: "The EA app updates its games itself."))
    }

    func verify(_ id: String, install: StoreInstall, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard enabled else { throw Self.unavailable }
        throw StoreError.failed(String(localized: "The EA app repairs its games itself."))
    }

    func importGame(at folder: URL, library: [StoreGame]) async throws -> (StoreGame, StoreInstall) {
        guard enabled else { throw Self.unavailable }
        throw StoreError.failed(String(localized: "Add the game to the EA app first, then let it manage the install."))
    }

    func saveLocations(_ id: String, install: StoreInstall, prefix: URL) async throws -> [SaveLocation] { [] }
    func syncSaves(_ id: String, locations: [SaveLocation], direction: SaveDirection, stamps: [String: String]) async throws -> [String: String] { stamps }

    @discardableResult
    func openLauncher() async throws -> any LauncherProcess {
        guard enabled else { throw Self.unavailable }
        return try await launcher.open()
    }

    // The store button: the game's web page when the library gave its slug, the catalog otherwise.
    func openStorePage(_ game: StoreGame?) async throws {
        guard enabled else { throw Self.unavailable }
        await backing.openWeb(LauncherLinks.storePage(store, slug: game.flatMap { api.slugs.value[$0.id] }))
    }
}

// installerdata.xml under ProgramData\EA Desktop\InstallerData: per-offer install paths.
// The file's real layout is unverified until the W1 test — the reader takes any
// installPath="…" attribute or <installPath> element on the offer's own line or block.
enum EAInstallLocation {

    static func path(for id: String, in prefix: URL) -> String? {
        let folder = prefix.appending(path: "drive_c/ProgramData/EA Desktop/InstallerData")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".xml") }.sorted()
        for file in files {
            guard let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8) else { continue }
            for block in Self.blocks(containing: id, in: text) {
                if let path = installPath(in: block) { return path }
            }
            // A manifest listing the offer without its own block carries the path elsewhere
            if !text.contains(id) { continue }
        }
        return nil
    }

    // The element (or bare line) the offer id sits in, bounded by the nearest blank lines.
    private static func blocks(containing id: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        for (i, line) in lines.enumerated() where line.contains(id) {
            var block = line
            // Grow up/down to the enclosing <game …>/<install …> element bounds when present
            var up = i
            while up > 0, !lines[up].contains("<game"), !lines[up].contains("<install") { up -= 1 }
            var down = i
            while down + 1 < lines.count, !lines[down].contains("</game"), !lines[down].contains("</install") { down += 1 }
            if up < i || down > i { block = lines[up...down].joined(separator: "\n") }
            out.append(block)
        }
        return out
    }

    static func installPath(in block: String) -> String? {
        // installPath="C:\…" or <installPath>C:\…</installPath>
        if let range = block.range(of: #"installPath="[^"]+""#, options: .regularExpression) {
            return String(block[range].dropFirst("installPath=\"".count).dropLast())
        }
        if let range = block.range(of: "<installPath>[^<]+</installPath>", options: .regularExpression) {
            return String(block[range].dropFirst("<installPath>".count).dropLast("</installPath>".count))
        }
        return nil
    }
}

extension StoreSecrets {
    // A small file the vault alone keeps: EA's token.json, Ubisoft's session stamp. Nothing
    // is materialized under stores/ — these stores never give a client a token file.
    func write(files: [String: Data], account: String, for store: GameSource) throws {
        try vault.write(StoreSecret(account: account, files: files), for: store)
    }
}
