# Cartouche technical requirements and architecture

How Cartouche is built, what it depends on, and what limits it. Read by contributors and reviewers. Product intent is in `docs/PRD.md`. Decisions are in `docs/adr/`.

Status: draft, updated by each phase. Date: 2026-10-19. One scope; first release v0.1.0. Phases P0, P1, P4, P9, P12 and P17 are merged and archived. The others are still proposals, and the text about them is a plan.

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
  Helpers/cartouche-mcp  --XPC-->  app          (MCP server for agents)
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

### Steam-side dylib (`dylib/`, inherited from NotProton)

- C code injected into the Mac Steam client with Dobby hooks.
- Registers compatibility tools, patches Steam's web UI (`feats/webpatch.c`), writes Steam shortcuts (`feats/usershortcuts.c`) and starts games (`feats/compat_run.sh`).
- P5 adds an export of the Steam library (owned games, collections, play time, installed state) from the code that already reads `window.appStore.m_mapApps`.
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
- Wine CrossOver is built from the CrossOver 26.3.0 source tarball (Wine 11.0 inside), pinned by URL, SHA-256 and size in `packaging/wine-crossover/pins.env`. The workflow `.github/workflows/wine-crossover.yml` runs on `macos-15-intel` with Xcode 16.4 and llvm-mingw 20261006. The asset `wine-crossover-26.3.0-1-x86_64.tar.xz` is published by CI. It carries the Wine license files and `SOURCE.md` (the source offer), and it bundles freetype, gnutls (with its libraries), MoltenVK and SDL2 with `@rpath` names. MSync is in these sources.
- WineHQ builds are the official macOS builds made by Gcenx, downloaded by the app and pinned in `runners.json` (wine-stable 11.0_1, wine-devel 11.18).
- Game Porting Toolkit is never in the repository, a release or a download we host. The app finds it in mounted volumes (`/Volumes/*/redist/lib`), apps with "Porting Toolkit" in their name in `/Applications` and `~/Applications`, the Homebrew kegs, and folders the user picked. The version comes from `D3DMetal.framework`. `packaging/redist-scan.sh` also scans tar archives and matches files by SHA-256 and size against `packaging/redist-hashes.txt`.
- D3DMetal is offered only from a ready GPTK copy or from a CrossOver that has `lib64/apple_gptk/external/D3DMetal.framework`. That path is not confirmed on a real CrossOver.
- Installed free runners live in `runners/wine-<id>/` (with a receipt of key file hashes) and `runners/gptk-<version>/lib` (receipt of every file hash). Downloads go to `~/Library/Caches/Cartouche/runners` and are deleted after unpacking. A download whose size or SHA-256 differs is deleted.
- Free runners are listed by the registry but not offered to Steam yet. Their ntdll hook offsets need the built ntdll. CI runs `ntdll-patch/resolve.py` and uploads the values. Then the maintainer pins them in `NtdllPatcher` and `SupportedRunner`, as for CrossOver builds. P3 lists their Steam tools.
- Each supported build is pinned: URL, size and SHA-256 in the runner manifest, ntdll hashes and RVAs in the code. `ntdll-patch/resolve.py` finds the RVAs.
- Backends (P3): D3DMetal, DXMT, DXVK, wined3d. DXMT and DXVK are downloaded with pinned SHA-256. D3DMetal comes only from the user's GPTK or CrossOver.
- A game setup is runner, backend, CPU translation and environment variables. The choice is written to Steam's `CompatToolMapping` through `SpecifyCompatTool`.
- Steam sees one compatibility tool per valid runner and backend pair, named `<runner> · <backend>`.

### InstallerKit (`installer/`)

- Swift package with no dependency on the app.
- Components: `PartScanner`, `Checksums`, `InnoInspector`, `GameName`, `SpaceEstimate`, `InnoCommand`, `ExeDetector`. CLI: `installer-inspect`.
- Analysis reads files and runs only `innoextract`. It never executes anything from the dropped folder.
- P6 adds the install runner: fresh prefix, Rosetta, Inno options (`/DIR`, `/LOG`, `/LANG`, `/NORESTART`), progress from the install folder size, stuck watchdog, retry fixes, winetricks for redistributables.

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

### MCP server for agents

- Helper binary `cartouche-mcp` in `Contents/Helpers/`, built with the official Swift MCP SDK. It speaks stdio to the client and XPC to the app.
- Tools cover PC and console games.
- Optional HTTP transport on 127.0.0.1 with a token. Off by default.
- Three access levels: Read only, Standard (default), Full. Tools above the level are refused.
- Anything that installs, deletes or runs an exe waits for approval in the app.
- An action log in Settings > Agents, with undo for configuration changes.
- Tools never return tokens, passwords, Keychain items or files outside the app folder and folders the user granted.
- Tool list: `mockup/MCP.md`.

### Sparkle updates

- Sparkle 2.10.0 checks `appcast.xml` in GitHub Releases once a day.
- The appcast is signed with an EdDSA key kept in CI secrets. The app trusts only Cartouche's public key and requires a signed feed (`SURequireSignedFeed`).
- Releases are signed with one self-signed certificate, so macOS grants survive updates. Tags, channels and certificate rotation: `docs/RELEASE.md`.
- Optional Beta channel, off by default (Settings > Receive beta updates). A critical flag can force the prompt after a Steam update breaks the dylib.
- Runners, backends and compatibility data update without an app update, through a manifest published by CI.

## Data stores

| Store | Location | Content | Phase |
|---|---|---|---|
| App data | `~/Library/Application Support/Cartouche` | Settings, runners, prefixes, caches | P0 |
| Logs | `~/Library/Logs/Cartouche` | App, Wine, game, installer logs | P0 |
| Runner manifest | `runners.json` in the app, a newer copy on the compat-data release | Format 1 and a revision. URL, size and SHA-256 per download. A newer copy is accepted only if valid, newer, and from https on github.com. It never changes the pin of a build the app already lists | P2 |
| Runner folders | `runners/` in the app data folder | `wine-<id>/`, `gptk-<version>/lib`, each with a receipt of file hashes | P2 |
| Runner downloads | `~/Library/Caches/Cartouche/runners` | Archives, deleted after unpacking | P2 |
| Compatibility cache | `compatibility/` in the app data folder | Last valid `compat.json.gz` and the time of the last contact | P4 |
| MacGamingDB cache | `compatibility/macgamingdb/<appid>.json` | One answer per game: aggregate rating and raw report rows. Never uploaded | P4 |
| Permission ledger and relaunch state | App defaults | What Cartouche asked, and the screen to reopen after a relaunch | P17 |
| Library store | App data folder | Cached Steam import, console games, favorites, hidden games | P5, P13 |
| Game setups | App data folder | Runner, backend, CPU, env per game | P3 |
| FPS store | SQLite in app data folder | Sessions: duration, average, 1% low, resolution, setup | P8 |
| Store tokens | macOS Keychain | Epic, GOG, Amazon tokens only | P10 |
| Steam config | Steam's own files | `CompatToolMapping`, `shortcuts.vdf` | P3, P5 |
| Agent action log | App data folder | Client name, time, action, previous value | P11 |

The compatibility schemas are in `docs/DATA-SCHEMA.md`. The FPS store schema (P8) will be added there. Privacy rules are in `docs/PRIVACY.md`.

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
| DXMT | DirectX 11 backend | To confirm in P3 | Downloaded, pinned SHA-256 |
| DXVK | Older DirectX games | zlib | Downloaded, pinned SHA-256 |
| innoextract | Inno Setup analysis | zlib | Bundled |
| winetricks | Redistributables | LGPL | Bundled |
| legendary, gogdl, nile | Epic, GOG, Amazon | GPL-3.0 | Bundled |
| comet | GOG online features | Apache-2.0 | Bundled |
| Swift MCP SDK | MCP server | To confirm in P11 | Linked into `cartouche-mcp` |
| RetroArch | Console frontend | GPL-3.0 | Built by our CI and bundled |
| libretro cores | Emulation | Varies per core; some are non-commercial | Never bundled. Downloaded per console |
| MacGamingDB | Mac reports | No data license published | Read live by the app. Never redistributed (ADR 0013) |
| AppleGamingWiki | Ratings per method | CC BY-NC-SA 3.0 | Read by CI, attribution and share-alike required |
| ProtonDB export | Linux reports, anti-cheat | ODbL | Read by CI, attribution and share-alike |
| AreWeAntiCheatYet | Anti-cheat status | MIT | Read by CI |

The table lists some components of phases that are not merged (P3, P6, P10, P11). P2 is in progress. Those rows are a plan. `THIRD-PARTY-LICENSES` lists what the repository ships today and will grow with those phases.

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
CI build of Wine CrossOver, WineHQ runner, GPTK detection. Manifest with SHA-256. The Runners model fetches a newer manifest at most once a day (`RunnerManifest.refresh`). Pinned ntdll offsets and Steam use of free runners are not done yet. Change: [`p2-free-runners`](../openspec/changes/p2-free-runners/).

### P3 Graphics backends
Per-game setup, one Steam tool per runner and backend pair, Mac or Windows version, pinned DXMT and DXVK. Change: [`p3-graphics-backends`](../openspec/changes/p3-graphics-backends/).

### P4 Compatibility data
Nightly JSON, offline-first client, per-Mac estimate, Linux anti-cheat data, attribution. MacGamingDB is read live, not published. Change: [`p4-compatibility-data`](../openspec/changes/archive/2026-10-19-p4-compatibility-data/). Spec: `openspec/specs/compatibility-data/`. Merged.

### P5 Library app
SwiftUI library, Steam import, favorites, search, all screen states, both macOS versions. Change: [`p5-library-app`](../openspec/changes/p5-library-app/).

### P6 Windows installer
Analysis, install with progress, retry, playable result. Change: [`p6-windows-installer`](../openspec/changes/p6-windows-installer/).

### P7 Downloads and activity
One activity slot, Steam download progress, cover reveal shader in Metal, notifications. Change: [`p7-downloads-activity`](../openspec/changes/p7-downloads-activity/).

### P8 Performance tracking
Frame counter injected in the Wine process (x86_64 and arm64), SQLite store, comparison of setups, opt-in sharing. Change: [`p8-performance-tracking`](../openspec/changes/p8-performance-tracking/).

### P9 Release pipeline
CI, stable self-signed signing, Sparkle appcast, Homebrew tap, upstream watch. Change: [`p9-release-pipeline`](../openspec/changes/archive/2026-10-19-p9-release-pipeline/). Spec: `openspec/specs/release-pipeline/`. Guide: `docs/RELEASE.md`. Merged. Its manual checks for the maintainer are listed in its evidence.

### P10 Store integrations
Epic, GOG and Amazon through bundled CLIs, tokens in the Keychain. Change: [`p10-store-integrations`](../openspec/changes/p10-store-integrations/).

### P11 Agent control
MCP server, access levels, approvals, action log. Change: [`p11-agent-control`](../openspec/changes/p11-agent-control/).

### P12 RetroArch bundle
CI builds RetroArch from a pinned commit, signs it and embeds it. Cartouche drives it over MCP stdio, with a fallback to UDP commands on older releases. Version choice in Settings > Consoles. Change: [`p12-retroarch-bundle`](../openspec/changes/archive/2026-10-19-p12-retroarch-bundle/). Spec: `openspec/specs/retroarch-runtime/`. Guide: `docs/RETROARCH.md`. Merged. Research: `docs/research/retroarch-frontend.md`.

### P13 Console library
Add Consoles, games added by checksum from the + sheet or watched folders, libretro covers, console game panel (Continue From save states, achievements count, look, input lag, hardcore, discs, BIOS status, CRT launch). Cores downloaded per console. Change: `p13-console-library` (opened on main).

### P14 Console extras
Netplay, RetroAchievements account linking, screen translation, Coach mode, iCloud save states. Change: `p14-console-extras`.

### P15 Controls
Controller status, remapping (Steam Input, `SDL_GAMECONTROLLERCONFIG`, RetroArch remap files), Mac keyboard and mouse options, controller for keyboard-only games, couch mode. Change: `p15-controls`. Research: `docs/research/controls.md`.

### P16 Standalone emulators
Detect and launch Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing and others. Not bundled. Change: `p16-standalone-emulators`. Research: `docs/research/bonus-emulators.md`.

### P17 Mac permissions
Change: [`p17-mac-permissions`](../openspec/changes/archive/2026-10-19-p17-mac-permissions/). Spec: `openspec/specs/mac-permissions/`. Merged. A `Permissions/` module: a catalog of every permission Cartouche or the programs it starts can meet (App Management, Accessibility for Steam and for Cartouche, Input Monitoring for games and for Cartouche, Downloads folder, Removable Volumes, Local Network, Notifications, Login Items, Keychain), state readers, an explanation sheet before each macOS prompt, deep links to the System Settings panes, and a relaunch service for Input Monitoring. Reuses NotProton's App Management detection. Grants survive updates because the signing identity is stable (P9). The module is complete, but the screens that host it come with later phases (Settings P5, onboarding P18, controls P15). User-facing rules: `docs/PRIVACY.md`.

### P18 Onboarding
Change `p18-onboarding`. dmg layout and README steps for opening a non-notarized app, Homebrew cask caveats, and a five-step first launch (Welcome with detection, PC games, Consoles, Folders and privacy, Ready). App Management is requested only in the PC games step. Mockup: `mockup/onboarding.html`.

## Open technical questions

- Not decided: the channel that carries the Steam library export from Steam's UI to the app.
- Not proven: injection of the frame counter with every runner (hardened runtime may block it). Proof is required in P8.
- Not proven: pausing Steam downloads through the injected code. Proof is required in P7.
- Not proven: `/DIR` and `/LOG` honored by modified Inno installers; the ratio of installed size to part size (2.5 is an assumption); `unarc.dll` behavior under Rosetta on many cores.
- Not proven: netplay relay availability. The RetroArch MCP tool list is pinned by a fixture at the current commit and compared in CI at every bump.
- Not proven: which macOS permissions apply without a relaunch on macOS 15, 26 and 27. Only Input Monitoring is assumed to need one. The P17 matrix is a manual check.
- Not proven: an update keeps macOS grants across two signed releases (P9 and P17 manual checks).
- Not decided: a setting to turn off the daily update check and the daily compatibility file download.
- Not decided: P16 spec. P13 to P15 are proposals on main.
