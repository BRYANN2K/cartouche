# Cartouche roadmap

One scope. Every phase below is built before the first public release, **v0.1.0**. Versions then follow 0.x until the maintainer declares 1.0.

Each phase is one OpenSpec change in `openspec/changes/`. A phase is done when every scenario of its specs has evidence, the orchestrator review passed, and the change is archived.

## Phases

| Phase | Change | Goal | Depends on |
|---|---|---|---|
| P0 | `p0-rebrand-cartouche` | The fork becomes Cartouche and can live next to NotProton | – |
| P1 | `p1-runner-model` | One runner model instead of CrossOver-only code | P0 |
| P2 | `p2-free-runners` | Cartouche Wine built from CodeWeavers' sources, WineHQ and GPTK as runners | P1 |
| P3 | `p3-graphics-backends` | D3DMetal, DXMT, DXVK, wined3d per game; Mac or Windows version | P2 |
| P4 | `p4-compatibility-data` | Nightly compatibility JSON and the per-Mac estimate | P0 |
| P5 | `p5-library-app` | The SwiftUI library, built for PC and console games, covers, every state | P0 (P1 interface) |
| P6 | `p6-windows-installer` | Install from a Windows installer, end to end, with game and cover matching | P1, InstallerKit |
| P7 | `p7-downloads-activity` | Activity slot, notifications, the cover reveal shader in Metal | P5, P6 |
| P8 | `p8-performance-tracking` | FPS measured per session and per setup | P3 |
| P9 | `p9-release-pipeline` | CI, free signing, Sparkle updates, Homebrew tap, upstream watch | P0 |
| P10 | `p10-store-integrations` | Epic, GOG and Amazon through legendary, gogdl, nile | P5, P6 |
| P11 | `p11-agent-control` | MCP server for agents: PC, console and controls tools | P5, P6, P8 (P13, P15 for their tools) |
| P12 | `p12-retroarch-bundle` | RetroArch built from source, embedded, driven over MCP; cores and BIOS | P0 |
| P13 | `p13-console-library` | Consoles in the library: add consoles and games, covers, panel, Continue From, launch | P5, P12 |
| P14 | `p14-console-extras` | Netplay, RetroAchievements, translation, iCloud saves, Coach mode | P13 |
| P15 | `p15-controls` | Controller status, remapping, Mac keyboard and mouse, couch mode | P5, P6, P13 |
| P16 | `p16-standalone-emulators` | Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing detected and launched | P13 |
| P17 | `p17-mac-permissions` | Every macOS permission asked at the right moment, explained, recoverable | P0 |
| P18 | `p18-onboarding` | First launch: install, Gatekeeper, detection, choices, permissions | P5, P17 |

## Current status (2026-10-21, end of day)

P0–P18 have code on main. P10 remains in `openspec/changes/`; the other phase changes are archived. Archival is not proof that every original criterion passed. Merged code and fixture tests do not replace real-service, real-game or clean-machine release checks.

The work merged on the integration branch on 2026-10-21 has not been compiled or run yet. Every item below marked "merged" is pending build and live check.

### Merged before 2026-10-21

- Cartouche Wine default/recommendation, pinned downloads and serialized first boot (ADR 0015); published builds register Steam compatibility tools. WineHQ/GPTK Steam support still depends on pinned hook offsets.
- Unified Add Games and live `InstallerKitDropClassifier` wiring (7b9f842 / 539fbe3): installers, installed folders, ROMs, mixed inputs and archive staging through bundled universal libarchive (ADRs 0016, 0023–0024). Encrypted archives are refused.
- Direct extraction for supported installers that unpack with their own helper programs (3bb5921), with live output verification and standard/guided recovery (93aa900 / 04d6b6f; ADRs 0017, 0025–0026). Unknown helpers remain the shipped Windows versions.
- Managed uninstall, safe in-place removal, save retention, ranked identification, privacy-gated cover search and PE runtime selection (ADRs 0018–0020). Imported games also support rename/re-identification; game-session cleanup preserves unrelated store clients.
- Full Steam owned-library export, account-matched cached/stale presentation, runtime token fetch with no-store/backoff, and Cartouche Wine compatibility tools (ADRs 0021–0022; 9214df4). Steam download progress, pause/resume and cancellation are wired.
- Installer inspection and detection, plus hermetic universal innoextract 1.10 with Inno support through 6.4.0 (8014773). Boost/liblzma are static pinned builds; no Homebrew runtime dependency.
- Local crash reports, Copy Summary and Collect Diagnostics (ADR 0029), and Your Play setup comparisons.
- Capability-gated Advanced options for Windows-game sources (397990d / a46a8bb; ADRs 0030–0031): MetalFX, AVX advertisement, MSync, high resolution and HUD. DLSS requires verified DXMT extension DLLs; D3DMetal DLSS and frame generation are not offered.
- Onboarding v2 (d7b3404; ADR 0032): seven steps, pinned Cartouche Wine recommendation, GPTK disk-image import, background tasks, durable choices and pending-work recovery. App Management is asked immediately before the Steam write in Stores. Welcome has Skip Setup; Ready opens the library.
- Settings rework (a9ceae3): Steam and Wine Prefixes replace legacy setup/prefix menus and the Steam Play Setup window. Prefix backups can be restored; CrossOver.app is no longer required for the free runner path.
- Main-actor process-wait and console ownership-probe fixes (64e0e19 / 2d09f81), real-ROM-only console detection, console/emulator uninstall, and reviewed French localization (22fda08 / b0a048c; `docs/l10n/glossary-fr.md`).

### Bugs from the 2026-10-21 tests

| Item | Subject | Status |
|---|---|---|
| I, H | Steam export token refused; Wine-build tools not seen by the app | Merged on main (cb248b2), pending live check after Repair |
| J | Controller not seen in Windows games | SDL3 runtime fix merged on main (1b05e2d); Cartouche Wine 26.3.0-2 in progress |
| A | D3DMetal with Cartouche Wine (Silksong) | Merged: launch scripts export the toolkit path, Get D3DMetal… |
| L | Play becomes Stop | Merged |
| E, F | One Steam repair action in Settings and onboarding | Merged |
| B | Extracted drops left in Caches | Merged, with migration of existing records |
| G | Starts With (Programme de lancement) | Merged |
| K | Repack cancel cleanup and retry | Merged |
| C | Banner after a dev `make deploy` | Not a code bug; Repair fixes it |
| D | Source label wording | No change |
| M | Mods and patches | Moved to 0.1.1 |

Also merged: drop handoff and Back to Add Games, direct-unpack fallback on Try Again (ADR 0034), the Cartouche Wine name (ADR 0033), French for the RetroArch console strings, and the release pipeline (libarchive and innoextract mandatory). Security and robustness fixes from the code review are merged: pinned and signature-checked RetroArch, core changes held, iCloud saves, per-client MCP names, Keychain, dylib hardening, InstallerKit hardening, tolerant `library.json`, prefix backups kept.

### Still required before v0.1.0

- First Mac build of the integration branch, then fixes for any failing tests.
- Live checks: Steam export after Repair; a controller with Cartouche Wine 26.3.0-2; D3DMetal on Silksong; repack install, cancel and direct-unpack fallback; CarX Street setup under Cartouche Wine.
- Cartouche Wine 26.3.0-2 (SDL3 for controllers, bundled Wine Mono and Wine Gecko) is in progress, not released.
- Maintainer tasks: GitHub billing or a self-hosted runner (`MACOS_RUNNER`), the signing certificate and secrets, the Sparkle EdDSA key, the Homebrew tap repository. See `docs/RELEASE.md`.
- Earlier evidence still open: real Steam owned-list freshness and account switching, tool registration and download controls; real runner first boot and frame-counter injection; user-supplied RAR coverage; real store sign-ins, two-Mac cloud saves, netplay and RetroAchievements; permissions on supported macOS versions; onboarding captures. QA persona runs (`qa/`) remain postponed, not passed.

### After v0.1.0

- 0.1.1: mods and patches (M). Run an .exe in the game's prefix, per-game DLL overrides, open the game's C: drive.
- Cartouche Wine 26.3.0-3: GStreamer. Plan in `docs/research/26.3.0-3-wine-gstreamer.md`.
- ISDone/unarc installer crash: research finds a Rosetta and WoW64 thunk race that the CrossOver 26.3 sources already work around. No new Wine patch is planned. The CarX Street setup check under Cartouche Wine confirms it or not.

The app repository stays private until v0.1.0. Wine build recipes and assets are public in BRYANN2K/cartouche-wine. The landing page is https://cartouche.bryann2k.dev, linked from About.

## Original dependency waves (historical build order)

```
Wave 1  P0                              (original starting point)
Wave 2  P1   P4   P9   P12  P17
Wave 3  P2   P5
Wave 4  P3   P6   P13
Wave 5  P7   P8   P14  P16  P18
Wave 6  P10  P15
Wave 7  P11                             → v0.1.0
```

Two phases run in parallel only when they touch different directories. Each runs in its own git worktree and branch `phase/<change-id>`. Inside `app/`, phases of the same wave own separate folders (for example `Library/`, `Installer/`, `Consoles/`, `Permissions/`).

## Release v0.1.0

- Everything above, with every scenario evidenced.
- Signed with the project's self-signed certificate, distributed through GitHub Releases and the Homebrew tap, updated by Sparkle.
- Release notes say what works and what is experimental (Coach mode).

## After v0.1.0

### v0.1.1
- **Share your stats.** Opt-in sharing of a game's play stats (FPS per setup, runner, backend, Mac model) from the game panel. Off by default; PRIVACY.md lists every field before it ships. Builds on P8's sharing payload, which v0.1.0 keeps in code but hides.
- **Game list on the website.** cartouche.bryann2k.dev lists games with the stars users gave them and the shared stats behind them. The site reads the shared reports; the app never needs an account.
