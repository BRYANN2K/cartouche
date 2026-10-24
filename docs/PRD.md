# Cartouche product requirements

What Cartouche is, who it is for, and what the first release (v0.1.0) must do. Read by the maintainer, contributors and agents before they write a spec.

Status: product requirements, updated 2026-10-20. Implementation status is tracked in `docs/ROADMAP.md`. Phases (P0 to P18) are defined in `docs/ROADMAP.md`.

## Problem

Windows games on an Apple silicon Mac are hard to run.

- Steam on Mac only offers the games that have a Mac build.
- Wine wrappers run an exe and leave the user alone with the errors.
- Existing launchers do not tell the user whether a game will run on their own Mac.
- Installing a multi-part Windows installer fails often and silently.
- Good runners (CrossOver) cost money, and free ones are scattered.

## Users

- **Mac player with a Steam library.** Wants Windows games from Steam to just play.
- **Player with games outside Steam.** Has Epic, GOG or Amazon games, or Windows installers of games they own.
- **Retro player.** Has game files of their own for older consoles.
- **Tinkerer.** Wants to pick the runner, the graphics backend and the CPU translation per game.
- **Agent user.** Wants Claude or another MCP client to install, tune and repair games.

## Goals

- One native Mac app that shows every game in one library and says what it takes to play it.
- Steam Play from inside the Mac Steam client, with free runners (Cartouche Wine by default, built from CodeWeavers' CrossOver sources) and a per-game choice of graphics backend.
- A Windows installer flow that checks files first, shows real progress and ends with a playable game.
- An estimate of rating, FPS and settings for the user's own Mac, from community reports.
- No cost, no server, no account with Cartouche.
- Safe for agents: clear access levels and approval for risky actions.

## Non-goals

- No DRM circumvention, no cracks, no Steam emulators, no piracy-specific features or wording.
- No downloading or linking to ROM, BIOS or game files. Cartouche works on the user's own files.
- No redistribution of D3DMetal or any Apple Game Porting Toolkit file.
- No app backend in v0.1.0. A public game list with user stars and opt-in statistics sharing is planned for the website in v0.1.1; its submission and hosting design is not yet decided.
- No notarization, no Mac App Store.
- No support for macOS older than 15.
- No claim that online play with anti-cheat works on a Mac.
- No pull requests to NotProton upstream. Cartouche is an independent fork.

## Scope

There is one scope. Everything planned (P0 to P18) is built before the first public release, which is v0.1.0. Later versions follow semver 0.x until the maintainer declares 1.0.

Source: the maintainer's scope decisions of 2026-10-19, recorded in `docs/ROADMAP.md`.

| Area | Phases | What the user gets |
|---|---|---|
| Identity, runners, backends | P0 to P3 | Own identity, runner model, free runners, per-game graphics backends |
| Data and library | P4, P5 | Compatibility data with the per-Mac estimate, SwiftUI library with PC and Consoles sections, Steam import |
| Installer and activity | P6, P7 | Windows installer, activity slot, notifications |
| Performance and release | P8, P9 | FPS tracking, release pipeline, updates |
| Stores and agents | P10, P11 | Epic, GOG and Amazon. MCP server for agents (PC and console tools) |
| Consoles | P12, P13, P14 | Bundled RetroArch, console library, console extras (netplay, RetroAchievements account linking, screen translation, Coach mode, iCloud save states) |
| Controls | P15 | Controller status, remapping, Mac keyboard and mouse options, couch mode |
| Standalone emulators | P16 | Detection and launch of Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing and others |
| Mac permissions | P17 | Each macOS permission asked when its feature is used, explained first, listed in Settings with a way to fix it |
| Onboarding | P18 | Install a non-notarized app (Open Anyway), then a five-step, skippable first launch that ends on a playable game |

P0–P18 have code on main. Merged does not mean all real-machine checks passed. See the archived changes and their evidence.

## Key user flows

### Library

1. The user opens Cartouche. The library lists every Steam game, installed or not, read from the running Steam client.
2. Games not installed show in black and white. Selecting one shows it in color.
3. The user searches, favorites or hides games.
4. The game panel is one chrome for a PC game and a console game: artwork, title, one metadata line, then modules in a fixed order (ADR 0037). A module that does not apply is omitted. The others stay put.
5. When Steam is closed, show the last account-matched export, labelled cached and potentially stale. Appmanifests supply installed games and installed status. localconfig.vdf supplies play data only, not ownership (ADR 0021).
6. When Steam is not installed, the Steam source offers Download Steam, Install with Homebrew (only if Homebrew is present) and Locate Steam.

### Steam Play

1. The user picks a setup for a game: runner, graphics backend, CPU translation.
2. Cartouche writes the choice to Steam, so Properties > Compatibility in Steam shows the same tool.
3. The user presses Play. Steam starts the game through Cartouche's compatibility tool.
4. For a game with a Mac build, the user chooses Mac version or Windows version.
5. After a crash, the panel suggests another backend to try.

### Add Games

The toolbar + opens one Add Games sheet with a drop zone and Choose… for files or folders of any type. A drop on the library window opens the same sheet. Automatic detection routes to the installer, installed-game import, console ROM import or other matching flow. There are no separate Windows Games… or Console Games… entries. The UI is merged in a47ffd3 / 51a8ece. The backend classifier is pending; without it the sheet says “Game detection is unavailable” (ADR 0024).

### Windows installer

1. The user drops an installer, folder, archive or ROM. Cartouche detects its type. Built-in extraction uses bundled pinned universal libarchive behind InstallerKit (ADR 0023; backend merged in 95b4e47, app adapter wired in 539fbe3). Target zip/zip64, 7z, tar.* and RAR4/RAR5; multi-volume and solid support require verification. Encrypted archives are refused. Already-installed Windows games can be used in place by default or copied (ADR 0018). A game extracted from a dropped archive is moved to the games location; it never stays in `~/Library/Caches`.
2. Cartouche analyses it without running anything: parts, missing parts, checksums, installer type, game name, space needed.
3. The user reviews the result. A missing required part blocks Install. A part the manifest calls optional only warns.
4. Cartouche installs in a fresh prefix under Rosetta, with real progress. The user can continue in the background.
5. On failure, Cartouche names the likely cause and offers retries (verify files, fewer threads, less memory, short path, other runner).
6. The user confirms which exe starts the game. Runtime detection reads PE imports, runs one winetricks verb at a time with a timeout and Skip, and uses Wine Mono for .NET (ADR 0020; merged in 307ad2c). After install, Starts With changes that exe without touching the prefix or settings (merged, pending build and live check).
7. Installer files are deleted only when the user asks, and go to the Trash.
8. Cartouche’s direct-unpack app implementation for supported installers that unpack with their own helper programs is merged in 3bb5921 (ADR 0017). Unsupported selection uses setup. When a direct unpack cannot run or fails, Try Again runs the original setup under Wine; the fallback is never automatic (ADR 0034; merged, pending build and live check). End-to-end app verification remains pending.
9. Merged: uninstall of a managed game moves it to the Trash and offers Keep save files. Removing an in-place import never deletes its source files.
10. Merged: identify by store IDs, engine metadata, exe version info, exe name, then folder names. Steam store search is a fallback gated by the online-lookups privacy choice (ADR 0019).

### Installation verification (accepted policy, live engine merged)

Track installed state separately from verification (ADR 0026; UI merged in 7f8773b, live engine merged in 93aa900 / 04d6b6f). A shipped checksum list or archive CRC always triggers full verification; Stop marks not verified and there is no skip checkbox. Script presence/sizes alone gives “verified (sizes)”. Without evidence, allow “Installed, not verified” with a discreet badge and panel line. Verify Files… permits later checks. Mismatch offers Retry with the standard method (default), Keep Anyway (advanced; not verified, mismatches logged), and Cancel. Retry uses shipped helpers/original settings, then guided real-installer execution under Wine last. Output-equivalence and local-corpus rules from ADR 0025 stand; the detection tree is approved by ADR 0028.

### Stores

1. The user signs in to Epic, GOG or Amazon on the store's own page. Cartouche keeps only the token, in the Keychain.
2. The store's games appear in the library.
3. They install, update, verify and launch with the same setup, estimate and FPS features as Steam games.
4. Each store page lists honestly what the bundled client supports.

### Consoles through RetroArch

1. The user configures consoles in Add Consoles. Game files and folders enter through the common Add Games sheet; automatic detection routes ROMs to console import. Cartouche identifies each file by checksum. Folders set in Settings > Library are watched and new games are added automatically.
2. Cartouche downloads only the core for each console the user added, and checks the BIOS files the user must supply.
3. The library has a Consoles section with one entry per console, and covers from the libretro thumbnails.
4. A console game uses that same panel. RetroArch adds a BIOS alert when firmware is missing, Continue From when a save state exists, and Play Together. Setup holds the core, the look, discs, input lag and Hardcore. Your Play holds play time and achievements. Dolphin and the other standalone emulators skip BIOS, Continue From and Play Together.
5. Play starts Cartouche's own bundled RetroArch with a CRT power-on effect. Cartouche drives it over MCP stdio.
6. The user can choose another RetroArch version in Settings > Consoles.

### Console extras

1. Netplay with friends through RetroArch's lobby.
2. Linking a RetroAchievements account.
3. Screen translation, which needs a translation service set up by the user.
4. Coach mode (experimental), which reads game memory through RetroArch's MCP tools.
5. iCloud save states.

### Controls

1. The game panel shows the connected controller and who handles the layout: Steam Input, Cartouche or RetroArch.
2. The user customizes the layout. Steam games use Steam Input, other PC games use `SDL_GAMECONTROLLERCONFIG`, console games use RetroArch remap files.
3. Mac keyboard and mouse options for Wine games: Cmd as Ctrl, Option as Alt, mouse locking, precise scrolling.
4. A keyboard-only game can be played with a controller.
5. Couch mode lets the user navigate Cartouche with a controller.
6. A virtual controller for the whole system is not possible with free signing. A virtual pad inside Wine is possible and is the riskiest part.

### Standalone emulators

1. Cartouche detects installed emulators such as Dolphin, PCSX2, PPSSPP, Azahar, xemu and Ryubing.
2. It launches them with the user's game files. It does not bundle them.

### Agents

1. The user adds the server with `claude mcp add cartouche -- cartouche-mcp`.
2. The agent reads the library, logs and crash reports, and diagnoses a failure.
3. The agent has PC tools and console tools. It proposes or applies a fix within the access level the user set (Read only, Standard, Full).
4. Anything that installs, deletes or runs an exe waits for the user's approval in the app.
5. The user sees every agent action in Settings > Agents and can undo configuration changes.

## Approved follow-ups (2026-10-21)

French uses vouvoiement and Apple macOS terms, with the glossary owned by l10n-fr at docs/l10n/glossary-fr.md. Local crash reports offer Copy Summary and Collect Diagnostics without network reporting. All Windows-game panels gain Advanced for the options in ADR 0030; runtime support awaits research-upscaling. These follow-ups are accepted, not complete. The static detection tree is approved by ADR 0028.

## Success measures

Each measure comes from a scenario in an OpenSpec change. A phase is done only when every scenario has evidence.

| Measure | Target | Phase |
|---|---|---|
| Bundle ID and name | `dev.bryann2k.cartouche`, `Cartouche` | P0 |
| NotProton files touched by a first launch | 0 (modification times unchanged) | P0 |
| Existing tests after the runner refactor | All pass, none removed or skipped | P1 |
| Free runner download | SHA-256 matches manifest; explicit first boot finishes before launch; cold initialization is not subject to the old 60 s window target (ADR 0015) | P2 |
| Apple files in repository and release assets | 0 matches in the CI scan | P2 |
| Backend applied at launch | Log shows the chosen d3d11 library only | P3 |
| Nightly compatibility file | Valid against the schema, under 25 MB gzip, dated that night | P4 |
| Offline use | Cached data shown; age shown when older than 3 days | P4 |
| Steam import | N games shown within 10 s of a signed-in Steam | P5 |
| Installer analysis of a two-part, 11 GB installer | Done within 30 s on an M4, nothing executed | P6 |
| Reveal shader | 60 fps on an M1 with app CPU use under 5% | P7 |
| FPS accuracy | 60 plus or minus 1 fps on a locked 60 fps scene, per backend | P8 |
| Measurement overhead | Under 1% FPS difference | P8 |
| Data sent by default | No request carries play data | P8 |
| Update delivery | Offered within 24 h, installs without a Gatekeeper prompt | P9 |
| Signing identity | Same designated requirement across two releases | P9 |
| Console game added by checksum | Identified and shown with its cover in the Consoles section | P13 |
| Store sign-in | No password field in Cartouche; games listed within 15 s | P10 |
| Agent access | Calls above the access level fail with an error naming the level | P11 |
| Secret leakage through MCP | 0 matches in the response scan | P11 |

## Legal line

- Cartouche is a launcher and a compatibility helper. It runs software the user already owns.
- It has no feature that bypasses DRM. It does not detect, copy or apply cracks. It does not emulate Steam.
- Nothing in the app, README, docs or website uses piracy wording. The installer feature is called "Install from a Windows installer".
- It never links to ROM, BIOS or game download sites. Missing BIOS files are reported by name, with the text "Dump it from your own console".
- UI copy for consoles says "your own game dumps".
- Cartouche does not ship D3DMetal or Game Porting Toolkit files. It detects the user's own copy. With Cartouche Wine, D3DMetal comes only from the user's Game Porting Toolkit.
- Anti-cheat is shown as Linux data from ProtonDB and AreWeAntiCheatYet. It is never presented as a Mac verdict.
- The project is not affiliated with NotProton, Valve, Apple or CodeWeavers.
- Community data keeps its licenses and is credited in the app: AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB export (ODbL), AreWeAntiCheatYet (MIT). MacGamingDB publishes no data license, so the app reads it live and never redistributes it (ADR 0013).

## Interface rules

From `FORK-PLAN.md` ("Règles d'interface"). Full rules will live in `docs/DESIGN.md` (P5).

- One panel for every game. Modules follow ADR 0037. A module with nothing to say is omitted. Details still holds the long report.
- One performance number: the user's FPS if they played, else the estimate for their Mac.
- No repeated information block. Sources are cited once, in Details.
- A suggestion appears only when it changes something.
- No section header for a single item.
- No decoration without a role: no gradients, badges, star ratings or colors that carry no state.

## Release details and open questions

- App repository: BRYANN2K/cartouche, private until v0.1.0. Public Wine build recipes and releases: BRYANN2K/cartouche-wine (ADR 0015). Landing page: https://cartouche.bryann2k.dev, linked from About.
- Personal Homebrew tap: BRYANN2K/homebrew-cartouche; complete the release guide’s setup and validation.
- Default core per console, and whether RetroArch playlists are only imported or also written back.
- Validate the merged controller mapping screens on physical devices (P15 evidence).
- List view, real sorting, a full-screen game page, several Steam accounts on one Mac, keyboard navigation of the grid.
