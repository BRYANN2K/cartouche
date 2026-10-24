# Changelog

What changed in each Cartouche release. Read by users, and by the release workflow: each tag publishes its own section below as the release notes in Sparkle and on GitHub.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow semver 0.x (ADR 0011). A section heading that ends in `(critical)` publishes a critical update.

## [Unreleased]

Merged on 2026-10-21, pending build and live check:

- Our Wine build, built from CodeWeavers' CrossOver sources (LGPL), is now called Cartouche Wine in the app and in Steam > Compatibility. It is not CrossOver. Runner IDs (`wine-crossover-*`) and existing installs are unchanged.
- Starts With (French: Programme de lancement): change the program an installed game starts with, from the game menu, the context menu or the panel's Setup section. The list follows the install sheet's ranking, and Choose Another… opens the game's folder. The prefix and settings are kept.
- Play becomes Stop while a game runs, in the panel, the card and the menus.
- D3DMetal with Cartouche Wine: launch scripts now export the full Wine environment, including the path to D3DMetal in your own Game Porting Toolkit. Stale launch scripts and records whose graphics this Mac can no longer load are rewritten. When only the toolkit is missing, the panel offers Get D3DMetal….
- Steam: one Repair action in Settings > Steam and in onboarding fixes a Cartouche install in Steam that does not match this app. While Steam runs, the action becomes Quit Steam and Repair, after a confirmation.
- Steam: once Cartouche has been set up in Steam, it puts this app's build back on its own at start, when the app becomes active and when Steam quits. It never quits Steam; while Steam runs, one line says the update waits for Steam to quit. The Repair action stays in Settings > Steam only when the automatic update failed. The Steam library reloads after the update and whenever Steam's export changes.
- Games extracted from a dropped archive are moved out of `~/Library/Caches` into the games location. Existing records that still point to Caches are moved at the next start.
- Add Games: the program and storage chosen on a drop reach the install sheet. Back returns to Add Games with the same drop.
- Cancelling a repack install cleans its folder and prefix, so the same install can start again.
- When a direct unpack fails, Try Again runs the original setup under Wine instead. The fallback is never automatic.
- Security and robustness: the official RetroArch download is pinned by size and SHA-256 and must carry libretro's Developer ID; a core build that differs from the recorded one is held until you ask again; iCloud saves download evicted files before switching; each MCP client's name is shown as a claim; tokens move to the data protection keychain; hardened Steam dylib and installer parsing; `library.json` and other JSON stores keep readable fields instead of resetting; Delete Prefix keeps the prefix's backups; a Wine build or the toolkit cannot be removed while a game uses it.
- French for the RetroArch console strings.
- Release builds fail if bundled libarchive or innoextract is missing.
- In progress, not released: Cartouche Wine 26.3.0-2, with SDL3 for controllers and bundled Wine Mono and Wine Gecko.

- Unified Add Games now classifies dropped installers, installed-game folders and console games, including archives extracted with bundled libarchive.
- Installed-game verification now uses a live engine: checksum/CRC verification, size-only checks, explicit not-verified status, later Verify Files, and standard-method recovery on mismatch.
- Seven-step onboarding keeps Wine installation, core downloads and GPTK imports running in the background and restores pending work after relaunch.
- Settings now owns Steam integration and Wine prefixes, including prefix backup restoration; the separate legacy setup window and menus are removed.
- Advanced Windows-game controls are gated by runner/backend support: MetalFX, AVX advertisement, MSync, high resolution and Metal HUD. Unsupported DLSS paths stay hidden; no frame generation.
- Steam export fetches its per-launch token at run time; Cartouche Wine builds register Steam compatibility tools.
- Steam downloads show progress, Pause/Resume and Cancel. Console games and emulator copies can be removed with explicit file-ownership choices.
- Quitting a game no longer terminates unrelated store clients; imported games support rename and re-identification. Console detection excludes non-ROM files.
- Remaining process waits and console ownership probes run outside main-actor view updates.

- French localization across the app, guided by `docs/l10n/glossary-fr.md` (vouvoiement, Apple terminology).
- Local crash reports: a post-crash prompt offers Show Report and Copy Summary, and a Collect Diagnostics command builds a zip locally; nothing is sent over the network.
- The Controls sheet shows a live controller diagram.
- Graphics menus and the game panel hide backends the game's setup can't use, with a single Get More Graphics Backends entry that leads to Cartouche Wine installation.
- innoextract 1.10 covers Inno Setup through 6.4.0 and is built universally from pinned sources with static Boost/liblzma, without a Homebrew runtime dependency.
- Your Play compares a game's measured performance across its setups (Compare Setups).
- The install review shown for installers that unpack directly stays accurate through the run.

- Fix a release-app crash caused by blocking process probes during SwiftUI updates; game menus use cached busy state.
- Fix Sparkle startup by enabling update verification before extraction; a release-feed test guards the setting.

- Import already-installed Windows games in place or copy them. In-place source files remain user-owned.
- Detect installers that unpack their data with their own helper programs, prepare their Wine environment, and directly extract supported formats; unsupported paths use the installer. Real-game coverage remains under validation.
- MCP agent control, console extras, controls, store integrations and performance tracking are merged. Real-machine and service checks remain before release.
- Wine builds are published from the public BRYANN2K/cartouche-wine build-recipe repository. The app repository stays private until v0.1.0.

- Cartouche starts from NotProton 1.2.0, renamed and with its own data folder, update feed and icon.
- Release pipeline: pull request checks, signed releases with Sparkle updates, a beta channel, a Homebrew tap and a nightly watch of upstream projects.
