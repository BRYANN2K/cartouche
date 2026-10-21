# Cartouche technical requirements and architecture

How Cartouche is built, what it depends on, and what limits it. Read by contributors and reviewers. Product intent is in `docs/PRD.md`. Decisions are in `docs/adr/`.

Status: updated 2026-10-20. One scope; first release v0.1.0. P0–P18 have code on main; P10 remains unarchived. Merged code still has manual checks. New decisions below are labelled planned where main does not implement them.

## Constraints

- **macOS 15 minimum.** Liquid Glass on macOS 26, classic materials on macOS 15. FEX only on macOS 26. See ADR 0004.
- **Free signing only.** One self-signed certificate, stable across releases. No notarization. See ADR 0003.
- **No server.** Compatibility data is a JSON file built nightly by CI. See ADR 0005. MacGamingDB is not in that file: the app reads it live. See ADR 0013.
- **Never bundle D3DMetal or any Game Porting Toolkit file.** The app detects the user's own copy. CI scans the repository and every release asset. See ADR 0007.
- **Apple silicon.** Windows code runs through Rosetta or, on macOS 26, FEX.
- **GPL-3.0.** Cartouche is an independent fork of NotProton and keeps its license. See ADR 0001. Third-party notices: `THIRD-PARTY-LICENSES`.
- **Bundle identifier `dev.bryann2k.cartouche`.** See ADR 0014.
- **No DRM circumvention and no piracy wording.** See the legal line in the PRD.
- **UI copy in English.**

## Architecture

```
Cartouche.app (SwiftUI, Swift 6)
  Library, Settings, Activity            reads: Runner registry, Game setups,
  Runner registry and installers                 compatibility cache, FPS store
  InstallerKit (Swift package)
  Compatibility client + estimate, MacGamingDB client
  Permissions module (catalog, explanation sheet, relaunch)
  Sparkle updater
  Helpers/cartouche-mcp  --Unix socket-->  app          (MCP server for agents, P11)
  RetroArch (bundled, built by CI) <--MCP stdio-- app
          |
          | writes Steam config, installs compat tools
          v
Steam (Mac client)
  Injected dylib (C): UI hooks, compat tools, shortcuts
  compat_run.sh -> runner (Wine) + backend -> game
```

### SwiftUI app (`app/`)

- Swift 6 and SwiftUI. The Swift package and its module are still named `NotProtonApp`. The product, bundle and user-facing name are Cartouche.
- Shows the library, the game panel, Settings, the activity slot and menu bar items.
- One source of truth: the app. The MCP server and the Steam shortcut call the same functions as the UI.
- Reuses the existing app code: `CrossOverSource`, `RunnerStore`, `RunnerInstaller`, `SupportedRunner`, `PinnedDownload`, `AppUpdater`, `SupportPaths`.
- Own names inside Steam (`cartouche.dylib`, `cartouche-proton*` tools, `CARTOUCHE_*` variables) come from one header, `cartouche_identity.h`. Install, Repair Steam and Remove Everything never touch an installed NotProton.

### Process probes outside view updates (fixed in f9bb3d7)

A release-app crash (AttributeGraph precondition failure) came from synchronous lsof/pgrep waits during SwiftUI updates: GameMenu.items → isBusy → lsof and LibraryModel.watch → SteamBundle.isRunning. GameMenu.items now reads cached per-game busy state and is pure. Busy refresh and Steam-presence probing run off the main actor. Uninstall planning/probes run detached before confirmation returns to the main actor. SystemStatus, SteamSetup, CoverBackdrop, PrefixTools and PrefixesModel also move blocking waits off the main actor.

Keep process inspection out of view/menu construction. Cached state is refreshed asynchronously; rendering must not wait for a subprocess. The fix is merged, not an open known issue. This documentation update does not claim a new crash-reproduction run.

### Library appearance (merged in 51a8ece)

The dark Liquid Glass layout uses a floating sidebar, cover-tinted backdrop, store/console brand marks and a four-column grid. Not-installed covers are grayscale with color reveal on download. The panel uses a red anti-cheat subtitle and media carousel with arrows and capped dots; red is not a new macOS anti-cheat verdict. Selection stays stable without slide animations, and narrow layouts dock content. Change Cover uses the same restyled sheet system. The integration owner reports 0% idle CPU and flat memory on the local run; this is not a performance guarantee for all Macs. Existing macOS 15 and accessibility requirements remain.

### Steam-side dylib (`dylib/`, inherited from NotProton)

- C code injected into the Mac Steam client with Dobby hooks.
- Registers compatibility tools, patches Steam's web UI (`feats/webpatch.c`), writes Steam shortcuts (`feats/usershortcuts.c`) and starts games (`feats/compat_run.sh`).
- P5 consumes SteamExport v1 `steam-library.json`. The full owned-list writer is merged in 451e393 / de0e6ec: the injected dylib registers a WebUI route through compatsvc’s route mechanism, validates a per-launch random token known only to Cartouche’s injected page script and the submitted payload, then atomically replaces the export (ADR 0022). No loopback HTTP listener, public Steam profile or user Web API key is used. With Steam closed, use the last account-matched export even if stale, labelled cached/stale. Appmanifests supply installed status; localconfig.vdf supplies play data only, never ownership (ADR 0021).
- P3 makes `compat_run.sh` set DLL overrides and environment variables per backend.
- Also in this tree: `lsteamclient/`, `steam-shim/`, `ntdll-patch/`, `overlay-shim/`, `bridge/`, `helpers/`.
- The dylib and the app share one data root and one set of Steam-side names through a generated header (P0). A test compares both sides.

### Runners and backends

- A runner has a source kind (CrossOver, Wine build, Game Porting Toolkit), a version, CPU flavors (Rosetta, FEX) and a state (available, installing, ready, damaged, unsupported).
- One registry lists runners. Every feature reads runners only from it (P1). CrossOver, the Wine builds and the user's Game Porting Toolkit copy are sources in the registry (P2).
- A build whose hashes are not pinned is listed as unsupported with the reason. It is not offered to Steam or to games.
- Damage detection: a cloned runner whose files no longer match their pinned hashes becomes damaged, with the file named, and Repair restores it.
- CrossOver behavior is unchanged by the runner model (a parity requirement of P1).
- Free runners (P2): Wine CrossOver built by our CI from CodeWeavers' LGPL sources, official WineHQ builds, and the user's own Game Porting Toolkit copied into `runners/` on their Mac.
- Wine CrossOver is built from the CrossOver 26.3.0 source tarball (Wine 11.0 inside), pinned by URL, SHA-256 and size in `packaging/wine-crossover/pins.env`. The build recipe and release assets are published from the public `BRYANN2K/cartouche-wine` repository. The private app repository `BRYANN2K/cartouche` stays private until v0.1.0. Build-tool pins belong to the public recipe, not this app document (ADR 0015). It carries the Wine license files and `SOURCE.md` (the source offer), and it bundles freetype, gnutls (with its libraries), MoltenVK and SDL2 with `@rpath` names. MSync is in these sources.
- WineHQ builds are the official macOS builds made by Gcenx, downloaded by the app and pinned in `runners.json` (wine-stable 11.0_1, wine-devel 11.18).
- Game Porting Toolkit is never in the repository, a release or a download we host. The app finds it in mounted volumes (`/Volumes/*/redist/lib`), apps with "Porting Toolkit" in their name in `/Applications` and `~/Applications`, the Homebrew kegs, and folders the user picked. The version comes from `D3DMetal.framework`. `packaging/redist-scan.sh` also scans tar archives and matches files by SHA-256 and size against `packaging/redist-hashes.txt`.
- D3DMetal is offered only from a ready GPTK copy or from a CrossOver that has `lib64/apple_gptk/external/D3DMetal.framework`. That path is not confirmed on a real CrossOver.
- Installed free runners live in `runners/wine-<id>/` (with a receipt of key file hashes) and `runners/gptk-<version>/lib` (receipt of every file hash). Downloads go to `~/Library/Caches/Cartouche/runners` and are deleted after unpacking. A download whose size or SHA-256 differs is deleted.
- Free runners are listed by the registry but not offered to Steam yet. Their ntdll hook offsets need the built ntdll. CI runs `ntdll-patch/resolve.py` and uploads the values. Then the maintainer pins them in `NtdllPatcher` and `SupportedRunner`, as for CrossOver builds. P3 lists their Steam tools.
- Each supported build is pinned: URL, size and SHA-256 in the runner manifest, ntdll hashes and RVAs in the code. `ntdll-patch/resolve.py` finds the RVAs.
- Backends (P3): D3DMetal, DXMT, DXVK, wined3d. DXMT and DXVK are downloaded pinned by version, size and SHA-256 in `Resources/backends.json` (DXMT 0.80 MIT, DXVK 1.10.3-20230507-repack zlib). D3DMetal comes only from the user's GPTK or CrossOver.
- A game setup is runner, backend, CPU translation and environment variables. The choice is written to Steam's `CompatToolMapping` through `SpecifyCompatTool`.
- Steam sees one compatibility tool per valid runner and backend pair, named `<runner> · <backend>`.
- A game installed from a Windows installer gets the same setup picker, limited to the install runners. `SetupEnvironment` builds the launch environment for store and installer games alike; `GameLauncher` rewrites `installs/<slug>/launch` in place, so the game and its prefix are never copied. Its record keeps the Wine version that last ran the prefix: picking an older Wine warns that the game may not start, and still applies.

### Unified Add Games (UI merged, backend pending)

ADR 0024 replaces separate Windows Games… / Console Games… entries. Toolbar + and library-window drops open the same Add Games sheet: drop zone and Choose… for files or folders of any type. The existing UI DropClassifying protocol connects to the shared DropClassifier backend; detection routes to installer/import, console ROM import or other matching flows. UI work is merged in a47ffd3 / 51a8ece; the InstallerKit backend is merged in 95b4e47 but its app adapter remains unwired in installer/AppAdapter/. Until DropClassifier is supplied to the app, the sheet shows “Game detection is unavailable”. See openspec/changes/unified-add-games/ and docs/research/unified-add-games.md for updated mockup notes.

### Local-game changes and remaining work (ADRs 0015–0020)

- CrossOver 26.3 Wine release `wine-crossover-26.3.0-1` is published from BRYANN2K/cartouche-wine. RELEASE.md records its size, hash and reused CI-build provenance. Default selection for new games when installed, the manifest pin, Graphics-menu reasons and serialized first boot are merged in 95b4e47; real-hardware checks remain pending. Among free Wine variants, CrossOver Wine alone enables D3DMetal and DXMT; D3DMetal also needs the user’s own GPTK files. Existing runner and ntdll validation remains required.
- Serialize first boot per prefix. Await successful initialization and Wine-server completion before installers or games run. Merged WineBootstrap uses explicit `wineboot -u` then `wineserver -w`, serialized per prefix; the gate precedes direct unpack and offers Show Log, Try Again and Recreate Prefix. A local repair took about eleven minutes; do not turn that observation into a sleep or a fixed deadline.
- Backend merged in 95b4e47: bundled pinned libarchive 3.8.9 (BSD-2-Clause), xz 5.8.4 and zstd 1.5.7, universal arm64+x86_64, behind CArchive and an InstallerKit Swift wrapper. Pins are in installer/libarchive/pins. The app adapter remains unwired. Never use system libarchive/bsdtar. Target zip/zip64, 7z, tar.* and RAR4/RAR5; multi-volume and solid coverage depends on the pinned build and must be verified with fixtures and the user-supplied real RAR. Refuse encrypted archives clearly. DropClassifier feeds the existing UI DropClassifying protocol, extracting archives then classifying installers, installed-game folders, ROMs, ROM archives and mixed inputs (ADR 0023).
- A Cartouche-owned driver directly extracts supported parts for installers with external unpackers. Main currently prepares Windows 10, short paths and runtimes, journals processes and still executes setup. The CLS Init_MapFile_ / unarc.dll FreeArcExtract recipe is now verified under WineHQ 11.18 on CarX Street: 905/905 real files MD5-verified, 22,703,585,753 bytes, exe present; one malformed manifest row is excluded. App implementation is merged in 3bb5921. Selection requires the Inno tmp/unarc.dll, tmp/arc.ini and cls-* entries, no password, and signature-checked FreeArc .bin parts; otherwise it uses setup. Missing-driver/failed-part automatic recovery is still absent, and the app end-to-end check is pending. See docs/research/direct-unpack-verification.md.
- In-place and copied Windows-game imports are merged. In-place is the default; the record stores the external game path and Cartouche owns only its prefix and record.
- Merged in 307ad2c: managed-game uninstall moves files to the Trash with an optional Keep save files copy. In-place removal trashes only the Cartouche prefix and record, leaving source files untouched. GameUninstall copies detected prefix save folders before trashing; a failed copy leaves the game in place. This is not app-level Remove Cartouche.
- Merged in 307ad2c: ranked identification uses GOG/Steam identity, installer title where present, engine metadata, PE product information, exe name and folder names. One Steam lookup path serves fallback identification and cover search, gated by the existing Fetch Mac reports from MacGamingDB choice. Epic-specific local metadata coverage is not established by this merge.
- Merged in 307ad2c: RuntimeScan reads PE imports from the main exe and adjacent DLLs, avoids runtimes already shipped beside the game, and uses Wine Mono for .NET. InstallEngine runs one winetricks verb per step with Skip and a 300-second verb timeout. This is an existing code constant, not a documentation change.

### Verified output and fallback (ADRs 0025–0026, UI merged in 7f8773b, engine pending)

The UI defines GameVerificationPresenting in Library/Verification/GameVerification.swift, with badge/panel status, Verify Files…, progress with Stop, and mismatch choices. Its default backend is nil; FixtureGameVerification is not a production verifier. Engine implementation and live wiring remain pending. ADR 0026 separates installed and verification states. Full: shipped checksum list or archive CRC, always checked, no skip; Stop marks not verified. Partial: script file presence/sizes, labelled “verified (sizes)”. Unavailable: allow installation as “Installed, not verified” with a discreet badge and panel line. Verify Files… supports later checks. Mismatch offers Retry with the standard method (default), Keep Anyway (advanced; not verified, mismatches logged), and Cancel. Retry uses shipped helpers/original settings before guided real-installer execution under Wine. No successful process exit alone grants verified status.

Optimizations may change speed only. Native helper replacements require exact version hashes on an allowlist; unknown helpers use shipped Windows versions. Every optimization needs byte-identical output on applicable local user-owned regression cases, including CarX Street, Lost in Random and Silksong RAR. Corpus files and verification data never leave the Mac. No helper hashes are selected here. The research-verified.md detection tree remains proposed.

### InstallerKit (`installer/`)

- Swift package with no dependency on the app.
- Components: `PartScanner`, `Checksums`, `InnoInspector`, `GameName`, `SpaceEstimate`, `InnoCommand`, `ExeDetector`. CLI: `installer-inspect`.
- Analysis reads files and runs only `innoextract`. It never executes anything from the dropped folder. The bundled innoextract is Homebrew 1.9, supporting Inno through 6.2.2; newer Inno support is not established.
- The install runner (P6): fresh prefix, Rosetta, Inno options (`/DIR`, `/LOG`, `/LANG`, `/NORESTART`), progress from the install folder size, stuck watchdog, retry fixes, winetricks for redistributables.

### Compatibility data pipeline (CI)

- A nightly GitHub Actions workflow (03:17 UTC) reads AppleGamingWiki, the ProtonDB monthly export and AreWeAntiCheatYet. The builder is `tools/compat`.
- It builds one gzip JSON file, validates it against `docs/schema/compat.schema.json`, and publishes it as the asset `compat.json.gz` of the `compat-data` release. That release is a pre-release, so the Sparkle feed on the latest release is unaffected.
- The file holds no MacGamingDB data. `tools/compat/check_published.py` fails if it names MacGamingDB. MacGamingDB publishes no data license (ADR 0013).
- If a source fails, the previous records for that source are kept with their old date and the source is marked stale.
- The app fetches the file at most once a day and keeps the last valid copy. It discards a file that fails the schema or is older than the copy in use.
- MacGamingDB is read live by the app from `/api/rest/games/{appid}`, only when a game's details or estimate are needed. Each answer is cached per game on the Mac, refreshed at most once a day, and the last good copy is kept offline. At most two requests run at once.
- Settings > Privacy has "Fetch Mac reports from MacGamingDB", on by default. Off, nothing is sent to macgamingdb.app and no estimate is shown. What leaves the Mac: `docs/PRIVACY.md`.
- The app computes the per-Mac estimate locally from the cached MacGamingDB report rows and the `gpu_strength` table of the data file. Comparable Macs are those with GPU strength within 1/1.4 to 1.4 times the user's Mac. With fewer than 3 reports, it uses the 5 closest.
- Schemas and data licenses: `docs/DATA-SCHEMA.md`.
- Anti-cheat data is stored and shown as Linux data only.

### Bundled RetroArch

- CI builds RetroArch from a pinned commit (git submodule, Xcode project in `pkg/apple`), signs it with the Cartouche certificate and embeds it in the app. No binary is committed.
- The pin is in `docs/RETROARCH.md` (commit `ed3187e`, reports 1.22.2). CI builds it twice and checks that `--version` names the pin and `--help` offers `--mcp-stdio`. The two builds are not expected to be byte-identical.
- Cartouche starts it with `--mcp-stdio` and drives it over stdin and stdout. RetroArch's MCP server exists on `master` but not in stable 1.22.2.
- With an official release older than the MCP server, Cartouche falls back to RetroArch's UDP network commands. Time Machine and Coach mode are then limited.
- Cores are never bundled. Each is downloaded from the libretro buildbot when the user adds that console.
- Settings > Consoles lets the user pick the included RetroArch, an official libretro release, or their own copy.
- RetroArch runs with its own `retroarch.cfg` and a Cartouche-owned `cartouche.cfg` passed with `--appendconfig`, both under Cartouche's folder. The user's `retroarch.cfg` is never read or written.
- Cores are verified by size and a SHA-256 recorded at first download, and checked at each launch. The buildbot publishes no signatures.
- Source offer for the GPL: `docs/RETROARCH.md` and `THIRD-PARTY-LICENSES`.
- Details: `docs/research/retroarch-frontend.md`.

### Standalone emulators (P16)

- Cartouche detects supported emulators in /Applications and ~/Applications (Dolphin, Ryubing and the catalog's others) and shows their version in Settings > Consoles.
- A console set to a standalone emulator launches the game with that emulator's documented arguments; the activity slot tracks it until it quits. A removed emulator falls back to the RetroArch core, or Play names what is missing.

### Console extras (P14)

- Netplay uses RetroArch's own host and connect flags. Host announces to libretro's lobby under the netplay nickname and plays through libretro's MITM relay. Join merges the lobby's list with Bonjour rooms on the local network (Local Network permission), and keeps only rooms whose game and core match the library.
- RetroAchievements: one sign-in, password sent once and never stored, token in the Keychain. Cartouche hashes a game file the way rcheevos does to find its game ID, and caches the unlock counts in `extras.json`. Hardcore turns off save states and rewind, and blocks input tools.
- Screen translation is RetroArch's AI service: the address comes from Settings > Consoles, per game, and the frame goes to that service only on request.
- iCloud Drive saves: `saves` and `states` become links into `iCloud Drive/Cartouche/`. Newer files win on merge; turning it off copies them back.
- Coach mode (experimental, off per game) reads named values parsed from the game's Rich Presence script through Cartouche's MCP relay. It never sends input in Hardcore.

### Store integrations (P10)

- Epic, GOG and Amazon are driven through open-source clients: legendary, gogdl, comet (GOG online features beside the game) and nile. Each is pinned by version, size and SHA-256 in `Resources/store-clients.json`, downloaded from its GitHub release on first use and checked before every run.
- Sign-in is each store's own web page; Cartouche reads only the one-time code. Tokens live in the Keychain; the client's token files are materialized into its private folder only while it runs, then collected back and deleted.
- Store games install, update, verify, launch, uninstall and import through the adapters with the same runner, backend and FPS features as Steam games. Epic and GOG cloud saves sync before launch and after exit. Installed games keep working on an expired session.
- Each store page states what its pinned client supports; Amazon lists cloud saves and online features as "Not supported yet" at nile 1.2.0.

### Controls (P15)

- Settings > Controllers and the game panel show connected controllers with name and battery.
- Remapping per game: Steam Input for Steam games (Cartouche defers to it), `SDL_GAMECONTROLLERCONFIG` for other Wine games, RetroArch remap files for console games.
- Mac keyboard and mouse options set the Wine Mac driver keys of the game's prefix. A controller-to-keyboard helper needs Accessibility and posts events only while the game is frontmost.
- Couch mode browses and launches with a controller only.

### Activity and performance (P7, P8)

- One activity slot in the sidebar shows the most important thing: a running game, then installs, downloads, updates. The status menu lists the rest.
- Steam downloads pause and resume through a command file the injected Steam page polls; a cover reveal shader in Metal tracks progress and respects Reduce Motion. Notifications fire on finished downloads and installs.
- The run script injects the frame counter after a per-runner probe; a runner that refuses it runs unmeasured and the panel says so. Sessions land in `performance/incoming/` and are folded into `sessions.sqlite`: average, 1% low, play time, per setup. Your Play and Compare Setups read them.

### Onboarding (P18)

- Five skippable steps: Welcome (detection), PC games, Consoles, Folders and privacy, Ready. The state resumes after a quit and re-run is in Settings.
- The PC games step offers a free runner and, only when the user sets Steam up, asks App Management by attempting the Steam write. It is the only macOS grant onboarding touches.

### MCP server for agents (P11, merged)

- Helper binary `cartouche-mcp` in `Contents/Helpers/`, built with the official Swift MCP SDK. It speaks stdio to the client and a Unix socket in the app's data folder to the app; the app admits only the bundled helper.
- Tools cover PC and console games.
- Optional HTTP transport on 127.0.0.1 with a token. Off by default.
- Three access levels: Read only, Standard (default), Full. Tools above the level are refused.
- Anything that installs, deletes or runs an exe waits for approval in the app.
- An action log in Settings > Agents, with undo for configuration changes.
- Tools never return tokens, passwords, Keychain items or files outside the app folder and folders the user granted.
- Agents reach RetroArch only through Cartouche's relay over RetroArch's own `--mcp-stdio`; input tools are refused in a Hardcore session.
- Tool list: `mockup/MCP.md`. Threat model: `SECURITY.md`.

### Sparkle updates

- Sparkle 2.10.0 checks `appcast.xml` in GitHub Releases once a day. `SUVerifyUpdateBeforeExtraction` is enabled in Info.plist (fix 8b6b29b); without it Sparkle refused to start with this configuration. ReleaseFeedTests guards the setting.
- The appcast is signed with an EdDSA key kept in CI secrets. The app trusts only Cartouche's public key and requires a signed feed (`SURequireSignedFeed`).
- Releases are signed with one self-signed certificate, so macOS grants survive updates. Tags, channels and certificate rotation: `docs/RELEASE.md`.
- Optional Beta channel, off by default (Settings > Receive beta updates). A critical flag can force the prompt after a Steam update breaks the dylib.
- Runners, backends and compatibility data update without an app update, through a manifest published by CI.

## Data stores

| Store | Location | Content | Phase |
|---|---|---|---|
| App data | `~/Library/Application Support/Cartouche` | Settings, runners, prefixes, caches | P0 |
| Logs | `~/Library/Logs/Cartouche` | App, Wine, game, installer logs | P0 |
| Runner manifest | `runners.json` in the app, a newer copy on the compat-data release | Format 1 and a revision. URL, size and SHA-256 per download. A newer copy is accepted only if valid, newer, from https on github.com, and verified by its EdDSA signature against SUPublicEDKey. It never changes the pin of a build the app already lists | P2 |
| Runner folders | `runners/` in the app data folder | `wine-<id>/`, `gptk-<version>/lib`, each with a receipt of file hashes | P2 |
| Runner downloads | `~/Library/Caches/Cartouche/runners` | Archives, deleted after unpacking | P2 |
| Compatibility cache | `compatibility/` in the app data folder | Last valid `compat.json.gz` and the time of the last contact | P4 |
| MacGamingDB cache | `compatibility/macgamingdb/<appid>.json` | One answer per game: aggregate rating and raw report rows. Never uploaded | P4 |
| Permission ledger and relaunch state | App defaults | What Cartouche asked, and the screen to reopen after a relaunch | P17 |
| Library store | `library.json`, `covers/` in the app data folder | Favorites, hidden games, chosen covers, per-game setups | P5 |
| Steam library cache | `steam-library.json` in the app data folder | The last export the Steam side wrote | P5 |
| Console library | `retroarch/` in the app data folder | Consoles, games, cores, saves, states, `extras.json` | P13, P14 |
| Game setups | App data folder | Runner, backend, CPU, env per game | P3 |
| FPS store | `performance/sessions.sqlite` in the app data folder | Sessions: duration, average, 1% low, resolution, setup | P8 |
| Store records | `stores/` in the app data folder | Per-store `library.json`, per-game install records, client folders and private HOMEs | P10 |
| Store and RetroAchievements tokens | macOS Keychain | Epic, GOG, Amazon tokens; the RetroAchievements token | P10, P14 |
| Steam config | Steam's own files | `CompatToolMapping`, `shortcuts.vdf` | P3, P5 |
| Agent action log | App data folder | Client name, time, action, previous value | P11 |

The compatibility schemas and the FPS store schema are in `docs/DATA-SCHEMA.md`. Privacy rules are in `docs/PRIVACY.md`.

## External dependencies

| Dependency | Use | License | Bundled or downloaded |
|---|---|---|---|
| NotProton (upstream code) | Base of the app and dylib | GPL-3.0 (parts under Valve licenses, see NOTICE) | Source in the repository |
| Sparkle 2.10.0 | Updates | MIT | Bundled |
| Dobby | Function hooks in the dylib | Apache-2.0 | Cloned at a pinned commit, built from source |
| lsteamclient, steam-shim | Steam API bridge | Steamworks SDK License, BSD-3-Clause | Source in the repository |
| cJSON, jsoncpp | JSON in C and C++ | MIT, public domain or MIT | Source in the repository |
| Wine CrossOver (CodeWeavers sources) | Free runner | LGPL | Built by our CI, downloaded by the app. Bundles freetype, gnutls, MoltenVK, SDL2 |
| Wine (WineHQ builds, by Gcenx) | Secondary runner | LGPL | Downloaded by the app, not bundled |
| Game Porting Toolkit, D3DMetal | Runner and DirectX 12 backend | Apple license | Never bundled. The user's own copy |
| DXMT | DirectX 11 backend | MIT | Downloaded, pinned SHA-256 |
| DXVK | Older DirectX games | zlib | Downloaded, pinned SHA-256 |
| innoextract | Inno Setup analysis | zlib | Bundled |
| winetricks | Redistributables | LGPL | Downloaded, pinned |
| legendary, gogdl, nile | Epic, GOG, Amazon | GPL-3.0 | Downloaded, pinned SHA-256 |
| comet | GOG online features | Apache-2.0 | Downloaded, pinned SHA-256 |
| Swift MCP SDK | MCP server | See THIRD-PARTY-LICENSES | Linked into `cartouche-mcp` |
| RetroArch | Console frontend | GPL-3.0 | Built by our CI and bundled |
| libretro cores | Emulation | Varies per core; some are non-commercial | Never bundled. Downloaded per console |
| MacGamingDB | Mac reports | No data license published | Read live by the app. Never redistributed (ADR 0013) |
| AppleGamingWiki | Ratings per method | CC BY-NC-SA 3.0 | Read by CI, attribution and share-alike required |
| ProtonDB export | Linux reports, anti-cheat | ODbL | Read by CI, attribution and share-alike |
| AreWeAntiCheatYet | Anti-cheat status | MIT | Read by CI |

`THIRD-PARTY-LICENSES` lists what the repository ships today. P11 is merged; its archived evidence separates automated checks from manual checks.

## Security and trust boundaries

- Code injected into Steam is the riskiest part. It must fail closed: if a hook cannot be installed, Steam still starts.
- Downloaded runners and backends are verified by SHA-256 against a pinned manifest before use. A bad hash deletes the file.
- If the FPS counter cannot be injected, the game still starts.
- Details and reporting: `SECURITY.md`.

## Phases

Each phase is one OpenSpec change. Order, dependencies and waves: `docs/ROADMAP.md`.

### P0 Rebrand
Own name, bundle ID `dev.bryann2k.cartouche` (ADR 0014), data and log folders, Sparkle feed and key, icon. One data root constant shared with the dylib. Change: [`p0-rebrand-cartouche`](../openspec/changes/archive/2026-10-19-p0-rebrand-cartouche/). Spec: `openspec/specs/app-identity/`. Merged.

### P1 Runner model
Runner protocol, registry and states. CrossOver re-expressed on it with identical behavior. Damage detection by pinned hashes. Change: [`p1-runner-model`](../openspec/changes/archive/2026-10-19-p1-runner-model/). Spec: `openspec/specs/runner-management/`. Merged.

### P2 Free runners
CI build of Wine CrossOver, WineHQ runner, GPTK detection. Manifest with SHA-256. The Runners model fetches a newer manifest at most once a day (`RunnerManifest.refresh`). Pinned ntdll offsets and Steam use of free runners are not done yet. Change: [`p2-free-runners`](../openspec/changes/archive/2026-10-19-p2-free-runners/). Spec: `openspec/specs/runner-sources/`. Merged.

### P3 Graphics backends
Per-game setup, one Steam tool per runner and backend pair, Mac or Windows version, pinned DXMT and DXVK. Change: [`p3-graphics-backends`](../openspec/changes/archive/2026-10-19-p3-graphics-backends/). Spec: `openspec/specs/game-setup/`. Merged.

### P4 Compatibility data
Nightly JSON, offline-first client, per-Mac estimate, Linux anti-cheat data, attribution. MacGamingDB is read live, not published. Change: [`p4-compatibility-data`](../openspec/changes/archive/2026-10-19-p4-compatibility-data/). Spec: `openspec/specs/compatibility-data/`. Merged.

### P5 Library app
SwiftUI library, Steam import, favorites, search, all screen states, both macOS versions. The importer combines any account-matched export, installed manifests and play data. The Steam-side writer was added in 451e393 and merged in de0e6ec, closing the old archived P5 implementation gap. Change: [`p5-library-app`](../openspec/changes/archive/2026-10-19-p5-library-app/). Merged and archived. Real Steam freshness remains a manual check.

### P6 Windows installer
Analysis, install with progress, retry, playable result. Change: [`p6-windows-installer`](../openspec/changes/archive/2026-10-19-p6-windows-installer/). Spec: `openspec/specs/windows-installer/`. Merged.

### P7 Downloads and activity
One activity slot, Steam download progress, cover reveal shader in Metal, notifications. Change: [`p7-downloads-activity`](../openspec/changes/archive/2026-10-19-p7-downloads-activity/). Spec: `openspec/specs/activity/`. Merged. Pausing a real Steam download is a manual check in its evidence.

### P8 Performance tracking
Frame counter injected in the Wine process (x86_64 and arm64), SQLite store, comparison of setups, opt-in sharing that stays unavailable while MacGamingDB has no report endpoint. Change: [`p8-performance-tracking`](../openspec/changes/archive/2026-10-19-p8-performance-tracking/). Spec: `openspec/specs/performance-tracking/`. Merged. Injection on each real runner is a manual check in its evidence.

### P9 Release pipeline
CI, stable self-signed signing, Sparkle appcast, Homebrew tap, upstream watch. Change: [`p9-release-pipeline`](../openspec/changes/archive/2026-10-19-p9-release-pipeline/). Spec: `openspec/specs/release-pipeline/`. Guide: `docs/RELEASE.md`. Merged. Its manual checks for the maintainer are listed in its evidence.

### P10 Store integrations
Epic, GOG and Amazon through downloaded pinned CLIs, tokens in the Keychain. Change: [`p10-store-integrations`](../openspec/changes/p10-store-integrations/). Merged, not archived. Real sign-in and two-Mac cloud saves are maintainer steps in its evidence.

### P11 Agent control
MCP server, access levels, approvals, action log. Change: [`p11-agent-control`](../openspec/changes/archive/2026-10-19-p11-agent-control/). Merged and archived.

### P12 RetroArch bundle
CI builds RetroArch from a pinned commit, signs it and embeds it. Cartouche drives it over MCP stdio, with a fallback to UDP commands on older releases. Version choice in Settings > Consoles. Change: [`p12-retroarch-bundle`](../openspec/changes/archive/2026-10-19-p12-retroarch-bundle/). Spec: `openspec/specs/retroarch-runtime/`. Guide: `docs/RETROARCH.md`. Merged. Research: `docs/research/retroarch-frontend.md`.

### P13 Console library
Add Consoles, games added by checksum from the + sheet or watched folders, libretro covers, console game panel (Continue From save states, achievements count, look, input lag, hardcore, discs, BIOS status, CRT launch). Cores downloaded per console. Change: [`p13-console-library`](../openspec/changes/archive/2026-10-19-p13-console-library/). Spec: `openspec/specs/console-library/`. Merged.

### P14 Console extras
Netplay, RetroAchievements account linking with Hardcore, screen translation, Coach mode, iCloud Drive saves. Change: [`p14-console-extras`](../openspec/changes/archive/2026-10-19-p14-console-extras/). Merged and archived. Real lobby, live RetroAchievements, real iCloud sync and a second Mac are maintainer steps in its evidence.

### P15 Controls
Controller status, remapping (Steam Input, `SDL_GAMECONTROLLERCONFIG`, RetroArch remap files), Mac keyboard and mouse options, controller for keyboard-only games, couch mode. Change: [`p15-controls`](../openspec/changes/archive/2026-10-19-p15-controls/). Spec: `openspec/specs/controls/`. Merged. Research: `docs/research/controls.md`.

### P16 Standalone emulators
Detect and launch Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing and others. Not bundled. Change: [`p16-standalone-emulators`](../openspec/changes/archive/2026-10-19-p16-standalone-emulators/). Spec: `openspec/specs/standalone-emulators/`. Merged. Research: `docs/research/bonus-emulators.md`.

### P17 Mac permissions
Change: [`p17-mac-permissions`](../openspec/changes/archive/2026-10-19-p17-mac-permissions/). Spec: `openspec/specs/mac-permissions/`. Merged. A `Permissions/` module: a catalog of every permission Cartouche or the programs it starts can meet (App Management, Accessibility for Steam and for Cartouche, Input Monitoring for games and for Cartouche, Downloads folder, Removable Volumes, Local Network, Notifications, Login Items, Keychain), state readers, an explanation sheet before each macOS prompt, deep links to the System Settings panes, and a relaunch service for Input Monitoring. Reuses NotProton's App Management detection. Grants survive updates because the signing identity is stable (P9). The module and its host screens are merged (Settings P5, onboarding P18, controls P15). User-facing rules: `docs/PRIVACY.md`.

### P18 Onboarding
Change [`p18-onboarding`](../openspec/changes/archive/2026-10-19-p18-onboarding/). Spec: `openspec/specs/onboarding/`. Merged. dmg layout and README steps for opening a non-notarized app, Homebrew cask caveats, and a five-step first launch (Welcome with detection, PC games, Consoles, Folders and privacy, Ready). App Management is requested only in the PC games step. Mockup: `mockup/onboarding.html`.

## Open technical questions

- Merged Steam export (451e393 / de0e6ec): Cartouche.ExportOwnedGames#1 uses SteamClient WebUI transport, per-launch token prefix, a 4 MB payload limit, v1/account/type/name validation, atomic 0600 writes and symlink refusal. Page polling is every 15 seconds and sends on change. Reported automated checks: libexport-check 0 failures, library-export.js 20 checks. Real Steam freshness and account switching remain manual checks; closed-client ownership is cached, never inferred from localconfig.vdf.
- Not proven on real runners: frame counter injection per runner; the probe exists and a refused runner plays unmeasured (P8 evidence).
- Not proven on a real Steam: Pause and Resume reach `SteamClient.Downloads` through the injected page (P7 evidence, manual check M1).
- Not proven on real services: the netplay lobby and MITM relay, live RetroAchievements, real iCloud Drive sync and two physical Macs (P14 evidence). The RetroArch MCP tool list is pinned by a fixture at the current commit and compared in CI at every bump.
- Not proven on real accounts: store sign-in, one installed game per store, and two-Mac cloud saves (P10 evidence).
- Not proven: `/DIR` and `/LOG` honored by modified Inno installers; the ratio of installed size to part size (2.5 is an assumption); `unarc.dll` behavior under Rosetta on many cores.
- Not proven: which macOS permissions apply without a relaunch on macOS 15, 26 and 27. Only Input Monitoring is assumed to need one. The P17 matrix is a manual check.
- Not proven: an update keeps macOS grants across two signed releases (P9 and P17 manual checks).
- Implemented: Settings > General > Check for updates and compatibility data daily pauses both automatic checks. See PRIVACY.md.
- Pending: archive app wiring and real user-archive coverage; direct unpacker format coverage; real-hardware prefix/backend checks; v0.1.1 statistics submission and website hosting design.
