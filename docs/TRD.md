# Cartouche technical requirements and architecture

How Cartouche is built, what it depends on, and what limits it. Read by contributors and reviewers. Product intent is in `docs/PRD.md`. Decisions are in `docs/adr/`.

Status: draft, updated by each phase. Date: 2026-10-19. One scope; first release v0.1.0.

## Constraints

- **macOS 15 minimum.** Liquid Glass on macOS 26, classic materials on macOS 15. FEX only on macOS 26. See ADR 0004.
- **Free signing only.** One self-signed certificate, stable across releases. No notarization. See ADR 0003.
- **No server.** Compatibility data is a JSON file built nightly by CI. See ADR 0005.
- **Never bundle D3DMetal or any Game Porting Toolkit file.** The app detects the user's own copy. CI scans the repository and every release asset. See ADR 0007.
- **Apple silicon.** Windows code runs through Rosetta or, on macOS 26, FEX.
- **GPL-3.0.** Cartouche is an independent fork of NotProton and keeps its license. See ADR 0001.
- **No DRM circumvention and no piracy wording.** See the legal line in the PRD.
- **UI copy in English.**

## Architecture

```
Cartouche.app (SwiftUI, Swift 6)
  Library, Settings, Activity            reads: Runner registry, Game setups,
  Runner registry and installers                 compatibility cache, FPS store
  InstallerKit (Swift package)
  Compatibility client + estimate
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

- Swift 6 and SwiftUI. Swift package `NotProtonApp` today; the name changes in P0.
- Shows the library, the game panel, Settings, the activity slot and menu bar items.
- One source of truth: the app. The MCP server and the Steam shortcut call the same functions as the UI.
- Reuses the existing app code: `CrossOverSource`, `RunnerStore`, `RunnerInstaller`, `SupportedRunner`, `PinnedDownload`, `AppUpdater`, `SupportPaths`.

### Steam-side dylib (`dylib/`, inherited from NotProton)

- C code injected into the Mac Steam client with Dobby hooks.
- Registers compatibility tools, patches Steam's web UI (`feats/webpatch.c`), writes Steam shortcuts (`feats/usershortcuts.c`) and starts games (`feats/compat_run.sh`).
- P5 adds an export of the Steam library (owned games, collections, play time, installed state) from the code that already reads `window.appStore.m_mapApps`.
- P3 makes `compat_run.sh` set DLL overrides and environment variables per backend.
- Also in this tree: `lsteamclient/`, `steam-shim/`, `ntdll-patch/`, `overlay-shim/`, `bridge/`, `helpers/`.
- The dylib and the app share one data root through a generated header (P0).

### Runners and backends

- A runner has a source kind (CrossOver, Wine build, Game Porting Toolkit), a version, CPU flavors (Rosetta, FEX) and a state (available, installing, ready, damaged, unsupported).
- One registry lists runners. Every feature reads runners only from it (P1).
- Free runners (P2): Wine CrossOver built by our CI from CodeWeavers' LGPL sources, official WineHQ builds, and the user's own Game Porting Toolkit copied into `runners/` on their Mac.
- Each supported build is pinned in a manifest: URL, SHA-256, ntdll hashes and RVAs. `ntdll-patch/resolve.py` finds the RVAs.
- Backends (P3): D3DMetal, DXMT, DXVK, wined3d. DXMT and DXVK are downloaded with pinned SHA-256. D3DMetal comes only from the user's GPTK or CrossOver.
- A game setup is runner, backend, CPU translation and environment variables. The choice is written to Steam's `CompatToolMapping` through `SpecifyCompatTool`.
- Steam sees one compatibility tool per valid runner and backend pair, named `<runner> · <backend>`.

### InstallerKit (`installer/`)

- Swift package with no dependency on the app.
- Components: `PartScanner`, `Checksums`, `InnoInspector`, `GameName`, `SpaceEstimate`, `InnoCommand`, `ExeDetector`. CLI: `installer-inspect`.
- Analysis reads files and runs only `innoextract`. It never executes anything from the dropped folder.
- P6 adds the install runner: fresh prefix, Rosetta, Inno options (`/DIR`, `/LOG`, `/LANG`, `/NORESTART`), progress from the install folder size, stuck watchdog, retry fixes, winetricks for redistributables.

### Compatibility data pipeline (CI)

- A nightly GitHub Actions workflow reads MacGamingDB, AppleGamingWiki, the ProtonDB monthly export and AreWeAntiCheatYet.
- It builds one gzip JSON file, validates it against `docs/schema/compat.schema.json`, and publishes it as a release asset.
- If a source fails, the previous records for that source are kept with their old date.
- The app fetches the file at most once a day and keeps the last valid copy.
- The app computes the per-Mac estimate locally from raw report rows. Comparable Macs are those with GPU strength within 0.7x to 1.4x of the user's Mac. With fewer than 3 reports, it uses the 5 closest.
- Anti-cheat data is stored and shown as Linux data only.

### Bundled RetroArch

- CI builds RetroArch from a pinned commit (git submodule, Xcode project in `pkg/apple`), signs it with the Cartouche certificate and embeds it in the app. No binary is committed.
- Cartouche starts it with `--mcp-stdio` and drives it over stdin and stdout. RetroArch's MCP server exists on `master` but not in stable 1.22.2.
- With an official release older than the MCP server, Cartouche falls back to RetroArch's UDP network commands. Time Machine and Coach mode are then limited.
- Cores are never bundled. Each is downloaded from the libretro buildbot when the user adds that console.
- Settings > Consoles lets the user pick the included RetroArch, an official libretro release, or their own copy.
- A Cartouche-owned override config is passed with `--appendconfig`. The user's `retroarch.cfg` is never rewritten.
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
- The appcast is signed with an EdDSA key kept in CI secrets. The app trusts only Cartouche's public key.
- Optional Beta channel. A critical flag can force the prompt after a Steam update breaks the dylib.
- Runners, backends and compatibility data update without an app update, through a manifest published by CI.

## Data stores

| Store | Location | Content | Phase |
|---|---|---|---|
| App data | `~/Library/Application Support/Cartouche` | Settings, runners, prefixes, caches | P0 |
| Logs | `~/Library/Logs/Cartouche` | App, Wine, game, installer logs | P0 |
| Runner manifest | Shipped with the app, refreshed with compat data | URL, SHA-256, ntdll pins per build | P2 |
| Compatibility cache | App data folder | Last valid `compat.json` | P4 |
| Library store | App data folder | Cached Steam import, console games, favorites, hidden games | P5, P13 |
| Game setups | App data folder | Runner, backend, CPU, env per game | P3 |
| FPS store | SQLite in app data folder | Sessions: duration, average, 1% low, resolution, setup | P8 |
| Store tokens | macOS Keychain | Epic, GOG, Amazon tokens only | P10 |
| Steam config | Steam's own files | `CompatToolMapping`, `shortcuts.vdf` | P3, P5 |
| Agent action log | App data folder | Client name, time, action, previous value | P11 |

Schemas will be written in `docs/DATA-SCHEMA.md` (P4, P8). Privacy rules will be in `docs/PRIVACY.md`.

## External dependencies

| Dependency | Use | License | Bundled or downloaded |
|---|---|---|---|
| NotProton (upstream code) | Base of the app and dylib | GPL-3.0 (parts under Valve licenses, see NOTICE) | Source in the repository |
| Sparkle 2.10.0 | Updates | MIT | Bundled |
| Dobby | Function hooks in the dylib | See NOTICE; to confirm in THIRD-PARTY-LICENSES | Built from source |
| lsteamclient, steam-shim | Steam API bridge | Steamworks SDK License, BSD-3-Clause | Source in the repository |
| cJSON, jsoncpp | JSON in C and C++ | MIT, public domain or MIT | Source in the repository |
| Wine CrossOver (CodeWeavers sources) | Free runner | LGPL | Built by our CI, downloaded by the app |
| Wine (WineHQ builds) | Secondary runner | LGPL | Downloaded by the app |
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
| MacGamingDB | Mac reports | MIT | Read by CI, API |
| AppleGamingWiki | Ratings per method | CC BY-NC-SA 3.0 | Read by CI, attribution required |
| ProtonDB export | Linux reports, anti-cheat | ODbL | Read by CI, attribution and share-alike |
| AreWeAntiCheatYet | Anti-cheat status | MIT | Read by CI |

`THIRD-PARTY-LICENSES` will list every notice (P2, P3, P6, P10).

## Security and trust boundaries

- Code injected into Steam is the riskiest part. It must fail closed: if a hook cannot be installed, Steam still starts.
- Downloaded runners and backends are verified by SHA-256 against a pinned manifest before use. A bad hash deletes the file.
- If the FPS counter cannot be injected, the game still starts.
- Details and reporting: `SECURITY.md`.

## Phases

Each phase is one OpenSpec change. Order, dependencies and waves: `docs/ROADMAP.md`.

### P0 Rebrand
Own name, bundle ID `app.cartouche.Cartouche`, data and log folders, Sparkle feed and key, icon. One data root constant shared with the dylib. Change: [`p0-rebrand-cartouche`](../openspec/changes/p0-rebrand-cartouche/).

### P1 Runner model
Runner protocol, registry and states. CrossOver re-expressed on it with identical behavior. Damage detection by pinned hashes. Change: [`p1-runner-model`](../openspec/changes/p1-runner-model/).

### P2 Free runners
CI build of Wine CrossOver, WineHQ runner, GPTK detection. Pinned ntdll offsets. Manifest with SHA-256. Change: [`p2-free-runners`](../openspec/changes/p2-free-runners/).

### P3 Graphics backends
Per-game setup, one Steam tool per runner and backend pair, Mac or Windows version, pinned DXMT and DXVK. Change: [`p3-graphics-backends`](../openspec/changes/p3-graphics-backends/).

### P4 Compatibility data
Nightly JSON, offline-first client, per-Mac estimate, Linux anti-cheat data, attribution. Change: [`p4-compatibility-data`](../openspec/changes/p4-compatibility-data/).

### P5 Library app
SwiftUI library, Steam import, favorites, search, all screen states, both macOS versions. Change: [`p5-library-app`](../openspec/changes/p5-library-app/).

### P6 Windows installer
Analysis, install with progress, retry, playable result. Change: [`p6-windows-installer`](../openspec/changes/p6-windows-installer/).

### P7 Downloads and activity
One activity slot, Steam download progress, cover reveal shader in Metal, notifications. Change: [`p7-downloads-activity`](../openspec/changes/p7-downloads-activity/).

### P8 Performance tracking
Frame counter injected in the Wine process (x86_64 and arm64), SQLite store, comparison of setups, opt-in sharing. Change: [`p8-performance-tracking`](../openspec/changes/p8-performance-tracking/).

### P9 Release pipeline
CI, stable self-signed signing, Sparkle appcast, Homebrew tap, upstream watch. Change: [`p9-release-pipeline`](../openspec/changes/p9-release-pipeline/).

### P10 Store integrations
Epic, GOG and Amazon through bundled CLIs, tokens in the Keychain. Change: [`p10-store-integrations`](../openspec/changes/p10-store-integrations/).

### P11 Agent control
MCP server, access levels, approvals, action log. Change: [`p11-agent-control`](../openspec/changes/p11-agent-control/).

### P12 RetroArch bundle
CI builds RetroArch from a pinned commit, signs it and embeds it. Cartouche drives it over MCP stdio, with a fallback to UDP commands on older releases. Version choice in Settings > Consoles. Change: `p12-retroarch-bundle` (opened on main). Research: `docs/research/retroarch-frontend.md`.

### P13 Console library
Add Consoles, games added by checksum from the + sheet or watched folders, libretro covers, console game panel (Continue From save states, achievements count, look, input lag, hardcore, discs, BIOS status, CRT launch). Cores downloaded per console. Change: `p13-console-library` (opened on main).

### P14 Console extras
Netplay, RetroAchievements account linking, screen translation, Coach mode, iCloud save states. Change: `p14-console-extras`.

### P15 Controls
Controller status, remapping (Steam Input, `SDL_GAMECONTROLLERCONFIG`, RetroArch remap files), Mac keyboard and mouse options, controller for keyboard-only games, couch mode. Change: `p15-controls`. Research: `docs/research/controls.md`.

### P16 Standalone emulators
Detect and launch Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing and others. Not bundled. Change: `p16-standalone-emulators`. Research: `docs/research/bonus-emulators.md`.

### P17 Mac permissions
Change `p17-mac-permissions`. A `Permissions/` module: catalog of every TCC permission Cartouche uses (App Management, Accessibility, Input Monitoring, Files and Folders, Local Network, Notifications, Login Items), state readers, an explanation sheet before each macOS prompt, deep links to System Settings panes. Reuses NotProton's App Management detection. Grants survive updates because the signing identity is stable (P9).

### P18 Onboarding
Change `p18-onboarding`. dmg layout and README steps for opening a non-notarized app, Homebrew cask caveats, and a five-step first launch (Welcome with detection, PC games, Consoles, Folders and privacy, Ready). App Management is requested only in the PC games step. Mockup: `mockup/onboarding.html`.

## Open technical questions

- Not decided: the channel that carries the Steam library export from Steam's UI to the app.
- Not proven: injection of the frame counter with every runner (hardened runtime may block it). Proof is required in P8.
- Not proven: pausing Steam downloads through the injected code. Proof is required in P7.
- Not proven: `/DIR` and `/LOG` honored by modified Inno installers; the ratio of installed size to part size (2.5 is an assumption); `unarc.dll` behavior under Rosetta on many cores.
- Not proven: the exact JSON shape of RetroArch's MCP tools on macOS builds, and netplay relay availability.
- Not decided: P16 spec. The P12 to P15 specs were being written on main when this was drafted.
