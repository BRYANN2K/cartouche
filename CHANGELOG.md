# Changelog

What changed in each Cartouche release. Read by users, and by the release workflow: each tag publishes its own section below as the release notes in Sparkle and on GitHub.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow semver 0.x (ADR 0011). A section heading that ends in `(critical)` publishes a critical update.

## [Unreleased]

## [0.1.2] - 2026-10-25

- Installing a Steam game from Cartouche: Accept and Install now goes through when Steam no longer serves the license it just showed ("No eula for app").
- A failed install no longer leaves Steam's install window open, which made every retry fail with "another-install". An install window still open for the same game is picked up again.
- Download progress follows Steam live. Cartouche read the byte count Steam writes to disk only every few minutes, so it could show 0% while Steam was at 5%.
- A download Steam sets aside to start another one shows as queued, not "Steam reported error 4".
- Install errors are explained in plain words, in French, Italian and Chinese too.
- Steam integration 0.1.2-1: Cartouche updates it in Steam on its own when Steam quits. Installing in the background needs it.

## [0.1.1] - 2026-10-25

- D3DMetal: onboarding and Settings > Runners name Apple's "Evaluation environment for Windows games", the download that holds D3DMetal, instead of "Game Porting Toolkit", the developer kit next to it. The link opens that search on Apple's site, and a dropped image without D3DMetal says which one to use.
- Cartouche says when Apple publishes a newer D3DMetal than the one on this Mac.
- DXMT and DXVK now download as soon as Cartouche Wine is installed. A game without D3DMetal uses DXMT instead of wined3d, which DirectX 11 games such as Raft refuse with "Failed to initialize graphics".
- A D3DMetal image already open in Finder is imported instead of failing with "Resource busy", and stays open.
- Homebrew: the cask moved to its own tap. Install with `brew tap bryann2k/cartouche && brew install --cask bryann2k/cartouche/cartouche`.
- README: how to uninstall Cartouche and give Steam back its own client.

## [0.1.0] - 2026-10-24

First public release.

- Our Wine build, built from CodeWeavers' CrossOver sources (LGPL), is now called Cartouche Wine in the app and in Steam > Compatibility. It is not CrossOver. Runner IDs (`wine-crossover-*`) and existing installs are unchanged.
- Starts With (French: Programme de lancement): change the program an installed game starts with, from the game menu, the context menu or the panel's Setup section. The list follows the install sheet's ranking, and Choose Another… opens the game's folder. The prefix and settings are kept.
- Play becomes Stop while a game runs, in the panel, the card and the menus.
- D3DMetal with Cartouche Wine: launch scripts now export the full Wine environment, including the path to D3DMetal in your own Game Porting Toolkit. Stale launch scripts and records whose graphics this Mac can no longer load are rewritten. When only the toolkit is missing, the panel offers Get D3DMetal….
- Steam: one Repair action in Settings > Steam and in onboarding fixes a Cartouche install in Steam that does not match this app. While Steam runs, the action becomes Quit Steam and Repair, after a confirmation.
- Steam: once Cartouche has been set up in Steam, it puts this app's build back on its own at start, when the app becomes active and when Steam quits. It never quits Steam; while Steam runs, one line says the update waits for Steam to quit. The Repair action stays in Settings > Steam only when the automatic update failed. The Steam library reloads after the update and whenever Steam's export changes.
- Games extracted from a dropped archive are moved out of `~/Library/Caches` into the games location. Existing records that still point to Caches are moved at the next start.
- Add Games: the program and storage chosen on a drop reach the install sheet. Back returns to Add Games with the same drop.
- Cancelling an install from an installer with an external unpacker cleans its folder and prefix, so the same install can start again.
- When a direct unpack fails, Try Again runs the original setup under Wine instead. The fallback is never automatic.
- Security and robustness: the official RetroArch download is pinned by size and SHA-256 and must carry libretro's Developer ID; a core build that differs from the recorded one is held until you ask again; iCloud saves download evicted files before switching; each MCP client's name is shown as a claim; tokens move to the data protection keychain; hardened Steam dylib and installer parsing; `library.json` and other JSON stores keep readable fields instead of resetting; Delete Prefix keeps the prefix's backups; a Wine build or the toolkit cannot be removed while a game uses it.
- French for the RetroArch console strings.
- Release builds fail if bundled libarchive or innoextract is missing.
- Cartouche Wine 26.3.0-2, with SDL3 for controllers and bundled Wine Mono and Wine Gecko, is pinned in the bundled runner list. Runner lists show the newest build and keep older installed ones.
- Games location: Settings > Library > PC Games > Games Location chooses where new Windows and store games install. Games already installed stay where they are, and every earlier location is still scanned.
- Wine Tools in the game menu: Winetricks…, Run Program in Prefix…, Open C: Drive and Show Log, on the game's own prefix. Running Steam games get a Stop.
- A banner in the library reports problems from the library, the stores and the consoles, and games that exit early with an error code. It offers Show Log, Copy Summary or the right Settings tab.
- Wine Prefixes lists every game's prefix. A crash in a Steam prefix ends with a `winedbg --auto` backtrace in the log instead of Wine's debugger dialog.
- Community contributions, off until the community service is live: Share My Results and Share a Fix for a game, My Contributions to track and withdraw them, and a Mac reports feed (Settings > Privacy). Nothing is sent without a preview and Share.
- Network politeness: a host that answers 429 or 503 is paused, honoring Retry-After with capped backoff. The local MCP token is stored in the Keychain.

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
- MCP agent control, console extras, controls, store integrations and performance tracking.
- Wine builds are published from the public BRYANN2K/cartouche-wine build-recipe repository.

- Cartouche starts from NotProton 1.2.0, renamed and with its own data folder, update feed and icon.
- Release pipeline: pull request checks, signed releases with Sparkle updates, a beta channel, a Homebrew cask and a nightly watch of upstream projects.
