import Foundation
import Testing

@testable import NotProtonApp

// The Keychain stand-in for tests: the real Keychain is never touched
final class MemoryVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoreSecret] = [:]
    private(set) var writes = 0
    // Set to make the next writes fail, as the Keychain does on a locked Mac
    var writeError: (any Error)?

    func read(_ store: GameSource) throws -> StoreSecret? { lock.withLock { items[store.id] } }
    func write(_ secret: StoreSecret, for store: GameSource) throws {
        if let writeError { throw writeError }
        lock.withLock { items[store.id] = secret; writes += 1 }
    }
    func delete(_ store: GameSource) throws { lock.withLock { items[store.id] = nil } }
}

// Stand-ins for legendary, gogdl, nile and comet: shell scripts that answer as
// the pinned versions do, from their source at the pinned tags (argument
// parsers, the JSON they print, the files they write and their log lines). They
// keep every call in state/<client>.calls and copy any token file they find to
// state/<client>.saw-token, so a test can tell what the vault put in place.
// Nothing here signs in to a real store.
enum StoreStubs {

    static func legendary(state: URL) -> String {
        #"""
        #!/bin/sh
        state='\#(state.path)'
        printf '%s\n' "$*" >> "$state/legendary.calls"
        cfg="$LEGENDARY_CONFIG_PATH"
        printf 'HOME=%s CONFIG=%s TMPDIR=%s\n' "$HOME" "$cfg" "$TMPDIR" >> "$state/legendary.env"
        [ -f "$cfg/user.json" ] && cp "$cfg/user.json" "$state/legendary.saw-token"
        refused() { echo '[cli] INFO: Logging in...' >&2; echo '[cli] ERROR: Login failed, cannot continue!' >&2; exit 1; }
        signed() { [ -f "$cfg/user.json" ] && [ ! -f "$state/expired" ] || refused; }
        [ "$1" = -y ] && shift
        cmd="$1"; shift
        case "$cmd" in
        auth)
          if [ "$1" = --code ]; then
            if [ "$2" != "$(cat "$state/epic-code")" ]; then echo '[cli] ERROR: Login attempt failed, please see log for details.' >&2; exit 0; fi
            cp "$state/epic-user.json" "$cfg/user.json"
            echo '[cli] INFO: Successfully logged in as "player42"' >&2
          elif [ "$1" = --delete ]; then
            rm -f "$cfg/user.json"; echo '[cli] INFO: User data deleted.' >&2
          fi ;;
        status) echo '{"account": "player42", "games_available": 2, "games_installed": 0, "egl_sync_enabled": false}' ;;
        list)
          signed
          mkdir -p "$cfg/metadata"; cp "$state"/epic-metadata/*.json "$cfg/metadata/"
          cat "$state/epic-list.json" ;;
        install)
          signed
          app="$1"; base=""
          while [ $# -gt 0 ]; do [ "$1" = --base-path ] && base="$2"; shift; done
          if [ -n "$base" ]; then
            dir="$base/$app"
            mkdir -p "$dir/Binaries"; printf 'MZ' > "$dir/Binaries/Game.exe"
            echo "$dir" > "$state/epic-installed-$app"
          fi
          for p in 12.50 50.00 100.00; do
            echo "[DLManager] INFO: = Progress: $p% (1/1), Running for 00:00:01, ETA: 00:00:00" >&2; sleep 0.2
            [ -f "$state/slow" ] && sleep 3
          done ;;
        list-installed)
          printf '['; sep=''
          for f in "$state"/epic-installed-*; do
            [ -f "$f" ] || continue
            app="${f##*/epic-installed-}"
            printf '%s{"app_name": "%s", "install_path": "%s", "title": "%s", "version": "1.0.1", "executable": "Binaries/Game.exe"}' "$sep" "$app" "$(cat "$f")" "$app"
            sep=', '
          done
          echo ']' ;;
        launch)
          app="$1"; offline=""
          for a in "$@"; do [ "$a" = --offline ] && offline=1; done
          [ -n "$offline" ] || signed
          dir="$(cat "$state/epic-installed-$app")"
          code="-AUTH_PASSWORD=exchange-code"; [ -n "$offline" ] && code=""
          printf '{"game_executable": "Binaries/Game.exe", "game_directory": "%s", "game_parameters": ["-windowed"], "egl_parameters": ["%s", "-epicapp=%s"], "user_parameters": [], "launch_command": [], "working_directory": "%s/Binaries", "environment": {"DXVK_LOG_LEVEL": "none", "HOME": "/tmp/legendary-home"}, "pre_launch_command": "", "pre_launch_wait": false}\n' "$dir" "$code" "$app" "$dir" ;;
        uninstall) rm -f "$state/epic-installed-$1" ;;
        import) echo "$2" > "$state/epic-installed-$1" ;;
        sync-saves) signed; echo "$*" >> "$state/legendary.saves" ;;
        esac
        exit 0
        """#
    }

    static func gogdl(state: URL) -> String {
        #"""
        #!/bin/sh
        state='\#(state.path)'
        printf '%s\n' "$*" >> "$state/gogdl.calls"
        [ "$1" = --auth-config-path ] || exit 2
        auth="$2"; shift 2
        [ -f "$auth" ] && cp "$auth" "$state/gogdl.saw-token"
        cmd="$1"; shift
        case "$cmd" in
        auth)
          if [ "$1" = --code ]; then
            if [ "$2" != "$(cat "$state/gog-code")" ]; then echo '{"error": true}'; exit 0; fi
            mkdir -p "$(dirname "$auth")"
            printf '{"46899977096215655": {"access_token": "gog-access", "refresh_token": "gog-refresh", "user_id": "4815", "expires_in": 3600, "loginTime": 1790000000}}' > "$auth"
            echo '{"access_token": "gog-access", "refresh_token": "gog-refresh", "user_id": "4815", "expires_in": 3600}'
          elif [ -f "$auth" ] && [ ! -f "$state/expired" ]; then
            echo '{"access_token": "gog-access", "refresh_token": "gog-refresh", "user_id": "4815", "expires_in": 3600}'
          else
            echo '[AUTH] ERROR: Failed to refresh credentials' >&2; echo 'null'
          fi ;;
        download|update|repair)
          id="$1"; base=""
          while [ $# -gt 0 ]; do [ "$1" = --path ] && base="$2"; shift; done
          # gogdl's contract: download puts the game folder under --path; update
          # and repair take the game folder itself (gogdl/args.py).
          if [ "$cmd" = download ]; then dir="$base/Sample GOG Game"; else dir="$base"; fi
          mkdir -p "$dir/bin"; printf 'MZ' > "$dir/bin/game.exe"
          printf '{"gameId": "%s", "rootGameId": "%s", "clientId": "5310", "name": "Sample GOG Game", "playTasks": [{"category": "game", "isPrimary": true, "name": "Play", "path": "bin\\\\game.exe", "arguments": "-skipintro", "type": "FileTask"}]}' "$id" "$id" > "$dir/goggame-$id.info"
          printf '{"buildId": "5310700"}' > "$dir/goggame-$id.id"
          for p in 25.00 75.00 100.00; do
            echo "[PROGRESS] INFO: = Progress: $p 100/400, Running for: 00:00:01, ETA: 00:00:00" >&2; sleep 0.2
          done ;;
        save-sync)
          [ -f "$auth" ] || { echo '[AUTH] ERROR: Failed to refresh credentials' >&2; exit 1; }
          echo "$*" >> "$state/gogdl.saves"
          path="$1"; id="$2"; name="__default"; way=""
          while [ $# -gt 0 ]; do case "$1" in --name) name="$2";; --skip-download) way=up;; --skip-upload) way=down;; esac; shift; done
          # The account's cloud, shared by every Mac of a test
          cloud="$state/cloud/$id/$name"; mkdir -p "$cloud" "$path"
          [ "$way" = up ] && cp -R "$path/." "$cloud/"
          [ "$way" = down ] && cp -R "$cloud/." "$path/"
          echo '1790000123.5' ;;
        esac
        exit 0
        """#
    }

    static func nile(state: URL) -> String {
        #"""
        #!/bin/sh
        state='\#(state.path)'
        printf '%s\n' "$*" >> "$state/nile.calls"
        cfg="$NILE_CONFIG_PATH/nile"
        mkdir -p "$cfg"
        [ -f "$cfg/current_user.json" ] && cp "$cfg/current_user.json" "$state/nile.saw-token"
        signed() { [ -f "$cfg/current_user.json" ] && [ ! -f "$state/expired" ] || { echo '[LIBRARY] ERROR: User not logged in' >&2; exit 1; }; }
        cmd="$1"; shift
        case "$cmd" in
        auth)
          case "$1" in
          --login)
            [ -f "$cfg/current_user.json" ] && { echo '[MAIN] ERROR: You are already logged in' >&2; exit 0; }
            printf '{"client_id": "414d415a4f4e", "code_verifier": "verifier-1", "serial": "SERIAL1", "url": "%s"}\n' "$(cat "$state/amazon-url")" ;;
          --logout) rm -f "$cfg/current_user.json" "$cfg"/*.enc ;;
          esac ;;
        register)
          code=""; client=""; verifier=""; serial=""
          while [ $# -gt 0 ]; do
            case "$1" in --code) code="$2";; --client-id) client="$2";; --code-verifier) verifier="$2";; --serial) serial="$2";; esac; shift
          done
          if [ "$code" = "$(cat "$state/amazon-code")" ] && [ "$client" = 414d415a4f4e ] && [ "$verifier" = verifier-1 ] && [ "$serial" = SERIAL1 ]; then
            echo '{"name": "Ana", "user_id": "amzn1.account.TEST"}' > "$cfg/current_user.json"
            printf 'encrypted-token' > "$cfg/0a1b2c.enc"
            cp "$state/amazon-library.json" "$cfg/library.json"
          else
            echo '[AUTH_MANAGER] ERROR: Failed to register a device' >&2
          fi ;;
        library)
          signed
          [ "$1" = list ] && cat "$cfg/library.json" ;;
        install|update|verify)
          signed
          id="$1"; base=""
          while [ $# -gt 0 ]; do [ "$1" = --base-path ] && base="$2"; shift; done
          if [ -n "$base" ]; then
            dir="$base/Sample Amazon Game"
            mkdir -p "$dir/Game"; printf 'MZ' > "$dir/Game/Sample.exe"
            printf '{\n  // fuel.json is JSON5\n  "SchemaVersion": "2",\n  "Main": {"Command": "Game\\\\Sample.exe", "Args": ["-prime"]},\n}\n' > "$dir/fuel.json"
            printf '[{"id": "%s", "version": "v7", "path": "%s"}]' "$id" "$dir" > "$cfg/installed.json"
          fi
          for p in 40.00 100.00; do echo "[PROGRESS] INFO: = Progress: $p 1/2, Running for: 00:00:01, ETA: 00:00:00" >&2; sleep 0.2; done ;;
        uninstall) rm -f "$cfg/installed.json" ;;
        import)
          path=""; id=""
          while [ $# -gt 0 ]; do case "$1" in --path) path="$2"; shift;; *) id="$1";; esac; shift; done
          printf '[{"id": "%s", "version": "v7", "path": "%s"}]' "$id" "$path" > "$cfg/installed.json" ;;
        esac
        exit 0
        """#
    }

    // comet: notes its arguments and whether the GOG tokens were there, then waits to be stopped
    static func comet(state: URL) -> String {
        #"""
        #!/bin/sh
        state='\#(state.path)'
        printf '%s\n' "$*" >> "$state/comet.calls"
        [ -f "$HOME/Library/Application Support/heroic/gog_store/auth.json" ] && touch "$state/comet.saw-token"
        trap 'touch "$state/comet.stopped"; exit 0' TERM
        sleep 30 & wait
        """#
    }

    // A Wine whose loader notes how the game was started and makes a prefix on wineboot
    static func wine(state: URL) -> String {
        #"""
        #!/bin/sh
        state='\#(state.path)'
        if [ "$1" = wineboot ]; then
          mkdir -p "$WINEPREFIX/drive_c/users/crossover/AppData/Local" "$WINEPREFIX/drive_c/windows/system32"
          touch "$WINEPREFIX/system.reg"; echo "wineboot $WINEPREFIX" >> "$state/wine.calls"; exit 0
        fi
        save="$WINEPREFIX/drive_c/users/crossover/Documents/Sample GOG Game/Saves/slot1.sav"
        {
          echo "args: $*"
          echo "pwd: $(pwd)"
          for v in WINEPREFIX CX_GRAPHICS_BACKEND WINEDLLOVERRIDES WINEDLLPATH DXVK_HUD MTL_HUD_ENABLED DXVK_LOG_LEVEL HOME; do
            eval "echo \"$v=\${$v}\""
          done
          [ -f "$save" ] && echo "found save: $(cat "$save")"
        } >> "$state/wine.calls"
        # The game saves, when the test asks it to
        if [ -f "$state/write-save" ]; then mkdir -p "$(dirname "$save")"; cp "$state/write-save" "$save"; fi
        # A game runs a moment, long enough for comet to start beside it
        sleep 0.5
        exit 0
        """#
    }

    static func install(_ script: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

// Recorded answers, in the shapes the pinned clients and the stores' APIs print
enum StoreFixtures {

    // legendary list --json: vars(Game) with its dlcs, from legendary/models/game.py
    static let epicList = #"""
    [{"app_name": "Fennec", "app_title": "Sample Free Game", "asset_infos": {"Windows": {"app_name": "Fennec", "build_version": "1.0.1"}},
      "base_urls": [], "metadata": {"keyImages": [{"type": "DieselGameBox", "url": "https://cdn1.epicgames.com/wide.jpg"},
        {"type": "DieselGameBoxTall", "url": "https://cdn1.epicgames.com/tall.jpg"}],
        "customAttributes": {"CloudSaveFolder": {"type": "STRING", "value": "{AppData}/SampleGame/Saved/{EpicId}"}}}, "dlcs": []},
     {"app_name": "Owl", "app_title": "Second Game", "asset_infos": {"Windows": {"app_name": "Owl"}}, "base_urls": [],
      "metadata": {"keyImages": []}, "dlcs": []}]
    """#

    static let epicMetadataFennec = #"""
    {"app_name": "Fennec", "app_title": "Sample Free Game", "metadata": {"customAttributes": {"CloudSaveFolder": {"type": "STRING", "value": "{AppData}/SampleGame/Saved/{EpicId}"}}}}
    """#

    // user.json as legendary writes it after auth --code
    static func epicUser(refreshEnds: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"access_token": "epic-access", "expires_at": "\#(iso.string(from: refreshEnds))", "refresh_token": "epic-refresh", "refresh_expires_at": "\#(iso.string(from: refreshEnds))", "account_id": "abc123", "displayName": "player42"}"#
    }

    // embed.gog.com/account/getFilteredProducts, two pages
    static let gogPage1 = #"""
    {"page": 1, "totalPages": 2, "totalProducts": 3, "productsPerPage": 2, "products": [
      {"id": 1207658924, "title": "Sample GOG Game", "image": "//images-1.gog-statics.com/abc", "worksOn": {"Windows": true, "Mac": false, "Linux": false}, "isGame": true},
      {"id": 1300000001, "title": "Soundtrack", "worksOn": {"Windows": true}, "isGame": false}]}
    """#
    static let gogPage2 = #"""
    {"page": 2, "totalPages": 2, "totalProducts": 3, "productsPerPage": 2, "products": [
      {"id": 1400000002, "title": "Mac Only Game", "worksOn": {"Windows": false, "Mac": true}, "isGame": true}]}
    """#
    static let gogUser = #"{"username": "galaxy_player", "userId": "4815", "galaxyUserId": "4815"}"#
    static let gogGamesDB = #"{"id": "x", "game": {"vertical_cover": {"url_format": "https://images.gog.com/cover{formatter}.{ext}"}}}"#
    static let gogRemoteConfig = #"""
    {"content": {"Windows": {"cloudStorage": {"enabled": true, "locations": [{"name": "saves", "location": "<?DOCUMENTS?>/Sample GOG Game/Saves"}]}}}}
    """#

    // nile library list --json: the entitlements nile saved in library.json
    static let amazonLibrary = #"""
    [{"id": "ent-1", "product": {"id": "amzn1.adg.product.SAMPLE", "title": "Sample Amazon Game",
      "productDetail": {"iconUrl": "https://m.media-amazon.com/icon.png", "details": {"logoUrl": "https://m.media-amazon.com/logo.png"}}}},
     {"id": "ent-2", "product": {"id": "amzn1.adg.product.OTHER", "title": "Other Prime Game", "productDetail": {"details": {}}}}]
    """#
}

// A scratch library, the four stand-in clients, a fake runner and a vault in memory
@MainActor
final class StoreScene {
    let work: URL
    let state: URL
    let steam: SteamFixture
    let defaults = ScratchDefaults()
    let model: LibraryModel
    let vault = MemoryVault()
    let folders: StoreFolders
    let files: StoreClientFiles
    let runners: URL
    let runner: Runner
    var center: StoreCenter!
    var server: StoreAPIServer?
    var base: URL?

    init(_ label: String, gogServer: Bool = false) async throws {
        work = try scratchDirectory("stores-\(label)")
        state = work.appending(path: "state")
        try FileManager.default.createDirectory(at: state.appending(path: "epic-metadata"), withIntermediateDirectories: true)
        steam = try SteamFixture("stores-\(label)")
        try steam.writeExport()
        model = libraryModel(steam, defaults: defaults)
        folders = StoreFolders(root: work.appending(path: "support/stores"))

        let bin = work.appending(path: "bin")
        var files = StoreClientFiles(root: folders.clients, downloads: work.appending(path: "downloads"))
        for (client, script) in [(StoreClient.legendary, StoreStubs.legendary(state: state)), (.gogdl, StoreStubs.gogdl(state: state)),
                                 (.nile, StoreStubs.nile(state: state)), (.comet, StoreStubs.comet(state: state))] {
            let url = bin.appending(path: client.rawValue)
            try StoreStubs.install(script, at: url)
            files.overrides[client] = url
        }
        self.files = files

        runners = work.appending(path: "runners")
        runner = try fakeRunner(in: runners, flavors: [.rosetta])
        let root = SupportPaths.clonedRoot(forBuild: runner.id, runners: runners)
        try StoreStubs.install(StoreStubs.wine(state: state), at: root.appending(path: "lib/wine/x86_64-unix/wine"))
        try StoreStubs.install("#!/bin/sh\nexit 0\n", at: root.appending(path: "bin/wineserver"))
        model.runners = [runner]

        try "epic-good-code".write(to: state.appending(path: "epic-code"), atomically: true, encoding: .utf8)
        try "gog-good-code".write(to: state.appending(path: "gog-code"), atomically: true, encoding: .utf8)
        try "amazon-good-code".write(to: state.appending(path: "amazon-code"), atomically: true, encoding: .utf8)
        try "https://www.amazon.com/ap/signin?openid.oa2.client_id=device:414d415a4f4e".write(
            to: state.appending(path: "amazon-url"), atomically: true, encoding: .utf8)
        try StoreFixtures.epicList.write(to: state.appending(path: "epic-list.json"), atomically: true, encoding: .utf8)
        try StoreFixtures.epicMetadataFennec.write(to: state.appending(path: "epic-metadata/Fennec.json"), atomically: true, encoding: .utf8)
        try StoreFixtures.epicUser(refreshEnds: Date().addingTimeInterval(8 * 3600))
            .write(to: state.appending(path: "epic-user.json"), atomically: true, encoding: .utf8)
        try StoreFixtures.amazonLibrary.write(to: state.appending(path: "amazon-library.json"), atomically: true, encoding: .utf8)

        if gogServer {
            let server = try StoreAPIServer()
            let base = try await server.start()
            server.put("/account/getFilteredProducts?mediaType=1&page=1", json: StoreFixtures.gogPage1)
            server.put("/account/getFilteredProducts?mediaType=1&page=2", json: StoreFixtures.gogPage2)
            server.put("/userData.json", json: StoreFixtures.gogUser)
            server.put("/platforms/gog/external_releases/1207658924", json: StoreFixtures.gogGamesDB)
            server.put("/components/galaxy_client/clients/5310?component_version=2.0.45", json: StoreFixtures.gogRemoteConfig)
            self.server = server
            self.base = base
        }
        center = makeCenter(folders: folders, vault: vault, library: model)
        await model.load()
    }

    // A center over these clients, GOG's APIs on the local server; another Mac gets its own folders and vault
    func makeCenter(folders: StoreFolders, vault: MemoryVault, library: LibraryModel?) -> StoreCenter {
        let secrets = folders.secrets(vault: vault)
        var gog = GOGAdapter(context: folders.context(.gog, files: files, secrets: secrets))
        if let base { (gog.embed, gog.remoteConfig, gog.gamesDB) = (base, base, base) }
        let center = StoreCenter(sharing: secrets, folders: folders, files: files, library: library, adapters: [
            .epic: EpicAdapter(context: folders.context(.epic, files: files, secrets: secrets)),
            .gog: gog,
            .amazon: AmazonAdapter(context: folders.context(.amazon, files: files, secrets: secrets)),
        ])
        center.runners = runners
        center.backends = work.appending(path: "backends")
        center.gameEnvironment = ["HOME": work.appending(path: "home").path, "PATH": "/usr/bin:/bin"]
        return center
    }

    func calls(_ client: String) -> [String] {
        ((try? String(contentsOf: state.appending(path: "\(client).calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func text(_ name: String) -> String {
        (try? String(contentsOf: state.appending(path: name), encoding: .utf8)) ?? ""
    }

    func flag(_ name: String, _ on: Bool = true) {
        let url = state.appending(path: name)
        if on { FileManager.default.createFile(atPath: url.path, contents: Data()) } else { try? FileManager.default.removeItem(at: url) }
    }

    // Every file under the stores folder whose content holds one of these tokens
    func filesHolding(_ tokens: [String]) -> [String] {
        let enumerator = FileManager.default.enumerator(at: folders.root, includingPropertiesForKeys: nil)
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            if tokens.contains(where: text.contains) { found.append(url.path.replacingOccurrences(of: folders.root.path, with: "")) }
        }
        return found
    }

    func signIn(_ store: GameSource, code: String) async {
        await center.beginSignIn(store)
        await center.finishSignIn(store, code: code)
    }

    @discardableResult
    func waitForJobs(within limit: Duration = .seconds(20)) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end, center.jobs.contains(where: { $0.phase == .running || $0.phase == .waiting }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !center.jobs.contains { $0.phase == .running || $0.phase == .waiting }
    }

    @discardableResult
    func waitUntil(within limit: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end, !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    func remove() {
        server?.stop()
        steam.remove()
        try? FileManager.default.removeItem(at: work)
    }
}
