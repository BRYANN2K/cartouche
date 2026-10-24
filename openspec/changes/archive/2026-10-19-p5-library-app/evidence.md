# Evidence: p5-library-app

Branch `phase/p5-library-app`, from main 6d88fe8, main 4fdc047 merged in. Machine: Apple silicon, macOS 27.0, Xcode beta (macOS 27 SDK), Swift 6.

No test reads or writes the real `~/Library`, Steam folder or Steam client. Every Steam file comes from `SteamFixture` (`app/Tests/NotProtonAppTests/LibraryFixtures.swift`), a scratch folder shaped like `~/Library/Application Support/Steam` for an account `player42` with the eight Steam games of `mockup/launcher.html`. Covers in the fixture are plain colored stand-ins with the game's name. The library store, the cover caches and the defaults are scratch too. No `steam://` link is opened: tests pass a recording opener.

The package has no XCUITest target, so "UI tests" drive the same models and menu lists the views bind to, and screenshots render the views offscreen. Run them again with `CARTOUCHE_SNAPSHOTS=<folder> swift test --package-path app --filter "SteamSetupTests|CoverTests|GamePanelTests|LibraryWindowTests|SettingsWindowTests"`.

## Tests

| Suite | Before (main 6d88fe8) | After |
|---|---|---|
| `make -s app-tests` | 696 tests, 43 issues | 759 tests, 43 issues |
| Failing test names (`✘ Test "…"` lines) | 38 lines | the same 38 lines (`diff` empty) |
| `make -s -o app-payload app && make -s l10ncheck` | 545 strings, 1 left in English | app built and signed ad hoc; 712 strings, the same 1 left in English |
| `make -s retroarch-tests` | – | 67 tests pass |
| `make -s packagingcheck` | – | pass |
| Hermetic C and script suites of `app.yml` (19) | – | all exit 0; no C, shell or JS file changed |
| `openspec validate --all --strict` | – | 19 passed, 0 failed |

- The failing tests are the known payload ones ("This build carries no components at all"): this worktree has no staged payload. No test was removed, skipped or changed except `UpdateChannelTests` reading `UpdatesSettingsView.swift`, which still holds `@AppStorage(UpdateChannel.betaDefaultsKey)`.
- New suites, in `app/Tests/NotProtonAppTests/`: "Steam's text files" and "Steam library import" (`SteamImportTests.swift`), "Steam not installed" (`SteamSetupTests.swift`), "Library browsing" (`LibraryModelTests.swift`), "Covers for PC games" (`CoverTests.swift`), "Game panel" (`GamePanelTests.swift`), "Keyboard and menus" (`GameMenuTests.swift`), "Library window and screen states", "Settings window" (`LibraryWindowTests.swift`).

## About the screenshots

Every PNG in `evidence/` is rendered offscreen (`NSView.cacheDisplay`) in an invisible window (alpha 0, ignores the mouse), in light and dark. The window server's own capture needs the Screen Recording permission, which this Mac does not grant, so:

- Drawn: SwiftUI text, images, shapes, Forms, pickers, toolbars, the grid, the panel, the sheet, grayscale covers (made black and white in the image itself, not by a layer filter).
- Not drawn: Liquid Glass, vibrancy and accent fills. The window's sidebar comes out blank and the selected sidebar row black; the Play and Download Steam buttons lose their fill; the panel title can come out dark on dark. These are capture artifacts. The sidebar is therefore also rendered on its own (`sidebar-*.png`).
- `*-macos15-*.png` are rendered on macOS 27 with the macOS 15 code path forced (`\.glassMode = .classic`: standard materials, `.borderedProminent`). They are not a macOS 15 run.

Manual checks for the maintainer are at the end.

## Scenarios

### Steam library import / Import from Steam
- Check: test `SteamImportTests.importFromSteam`; test `SteamImportTests.newExportWithinTenSeconds`; screenshot `evidence/library-steam-selected-gray-light.png`, `-dark.png`.
- Result: partial. The app side passes: with an export of 8 owned games and Steam running, the library shows 8 Steam games, 6 installed, and the toolbar reads "8 games. Signed in as player42" (account from `loginusers.vdf`). A new export file shows in the library 0.21 s after it is written (the app checks every 2 s, so at most about 2 s).
- Not done: the Steam side that writes the export (task 1.1). See "Task 1.1 blocked" below. Until it exists, a running Steam gives the installed games only, read from Steam's files.

### Steam library import / Steam closed
- Check: test `SteamImportTests.steamClosed`; test `SteamImportTests.noExport`; test `SteamImportTests.otherAccount`; test `SteamImportTests.damagedExport`.
- Result: pass. Steam closed with an export from earlier: the 8 cached games show; installed status comes from the manifests, not the export (God of War, installed in the export, is not installed by its manifest; Hollow Knight the reverse). Without any export, the 6 installed games show with play time from `localconfig.vdf` and the "Souls" collection from Steam's cloud storage file. An export from another account, or a damaged one, is ignored.

### Steam library import / Steam not installed
- Check: test `SteamSetupTests.screen`, `homebrewOnlyWhenPresent`, `download`, `downloadFails`, `locate`, `renders`; screenshot `evidence/state-steam-not-installed-light.png`, `-dark.png`, `-macos15-*`, `evidence/steam-not-installed-*.png`, `evidence/steam-not-installed-no-homebrew-*.png`.
- Result: pass. The Steam source shows "Install Steam" with Download Steam (Valve's `https://cdn.fastly.steamstatic.com/client/installer/steam.dmg`, mounted read-only, Steam.app copied to /Applications), "Install with Homebrew" with `brew install --cask steam` and Run only when `brew` is in `/opt/homebrew/bin` or `/usr/local/bin`, and "Steam is somewhere else" with Locate Steam…, which accepts only an app whose bundle ID is `com.valvesoftware.steam`. The sidebar badge reads Get. After an install, the screen asks to sign in once in Steam.
- Not run: the real download and Homebrew install (they would install Steam on this Mac). Manual check M3.

### Library browsing / Not installed is gray, selected is in color
- Check: test `LibraryModelTests.grayUntilSelected`; screenshots `evidence/library-all-games-*.png` (Apex Legends and God of War gray), `evidence/library-steam-selected-gray-*.png` (Apex Legends selected, in color).
- Result: pass.

### Library browsing / Favorite from the cover
- Check: test `LibraryModelTests.favoriteSurvivesRelaunch`; screenshot `evidence/library-all-games-*.png` (filled star on Elden Ring), `evidence/sidebar-*.png` (Favorites 1).
- Result: pass. The star at the top left of a cover calls `toggleFavorite`; the game is listed under Favorites; a new `LibraryModel` on the same `library.json` (a relaunch) still has it.

### Library browsing / Search
- Check: test `LibraryModelTests.searchNoMatch`; screenshot `evidence/state-no-search-result-*.png`.
- Result: pass. "zelda" gives "No games match “zelda”" with Clear Search; title Search, subtitle "0 results" (`toolbarText` "Search, 0 results"). Search ignores case and diacritics.

### Game panel / Panel content
- Check: test `GamePanelTests.panelOrder`, `detailsSheet`, `panelOpensTheGame`, `renders`; screenshots `evidence/panel-elden-ring-*.png`, `evidence/details-elden-ring-*.png`.
- Result: pass on the 2026-10-19 fixture (`tools/compat/fixtures/compat-2026-10-19.json.gz` and the recorded MacGamingDB answer; there is no 2026-10-18 fixture). Order: Play, Expected on This Mac (Good, 52 fps, High, 13 reports on an M4), Anti-Cheat on Linux (Online works on Linux, 9 of 9 reports), Graphics Reported on Macs (D3DMetal 21, DXMT 1, DXVK 1), Setup. The Details sheet holds Expected on This Mac, the Mac picker, All Mac Reports, AppleGamingWiki, Anti-Cheat on Linux, Advanced with the Metal Performance HUD, and the sources line. Opening the panel calls `CompatibilityModel.openGame(appID:)`: after rendering the panel, MacGamingDB's answer for 1245620 is in the model.

### Screen states / States are reachable
- Check: tests `LibraryWindowTests.loading`, `empty`, `offline`, `expired`, `steamMissing`, `noResult`, `otherStates`; `LibraryModelTests.loading`, `welcome`, `emptyFavorites`, `expiredStore`; screenshots `evidence/state-loading-*`, `state-empty-*`, `state-offline-*`, `state-expired-session-*`, `state-steam-not-installed-*`, `state-no-search-result-*`, `state-sign-in-*`, `state-empty-favorites-*`, `state-error-*`.
- Result: pass. Loading: skeleton covers, "Syncing…", subtitle "Syncing Steam library…". Empty: "Bring your games to this Mac" with Steam, Epic Games, GOG, Windows Installer. Offline: Offline item in the toolbar, Install disabled for games not installed. Expired session: banner "Your Epic Games session expired", games still listed, sidebar badge "!". Steam not installed and no search result as above. Error: "Cartouche couldn’t read your library" with Try Again.
- Note: the expired state is driven by setting the store's state; real store sessions come with P10.

### Native look on both macOS versions / macOS 15
- Check: screenshots `evidence/*-macos15-*.png`; test `LibraryWindowTests.glassMode`; `make -s mincheck` needs the payload, not run.
- Result: partial. Every glass element goes through `Glass.swift` with an `#available(macOS 26, *)` check and a standard-material fallback; the build targets macOS 15.0. The macOS 15 path renders every control on macOS 27. Not done: a run on a macOS 15 machine or runner (task 4.2 stays unticked). Manual check M1.

### Native look on both macOS versions / Reduce Motion
- Check: test `LibraryWindowTests.reduceMotion`.
- Result: pass on the logic. With Reduce Motion, `Motion` turns off the cover tilt and hover scale, the grid uses no animation, entrances are opacity fades, and the panel switch uses a 0.15 s ease instead of a spring. The skeleton pulse stops. Sheets are system sheets. Reduce Transparency replaces glass and materials with an opaque fill. Manual check M2 for the visual result.

### Keyboard and menus / Shortcuts work
- Check: test `GameMenuTests.commandD`, `commandI`, `play`, `everyActionInTheMenuBar`, `shortcuts`, `appShortcuts`.
- Result: pass on the menu model. With Red Dead Redemption 2 selected, the ⌘D item reads "Add to Favorites" and adds it to Favorites. ⌘I is Get Info, ⌘↩ is Play, ⌘F focuses search, ⌘, opens Settings. The context menu, the panel's More menu and the Game menu all render `GameMenu.items(for:in:)`, so every context action is in the menu bar. The old Install command gave up ⌘I. Not run: a real key press in the running app (no XCUITest target). Manual check M2.

### Built for PC and console games / Sidebar structure
- Check: test `LibraryModelTests.sidebar`; screenshot `evidence/sidebar-*.png`.
- Result: pass. Library (All Games 8, Favorites), PC (Steam 8, Epic Games, GOG and Amazon Games with "Sign In", Windows Installers), and an empty Consoles section with a + button that opens Add Games on Console Games. Add Games in the toolbar offers Windows Game… and Console Games….

### Built for PC and console games / Section titles are not repeated
- Check: test `LibraryModelTests.sectionHeaders`; screenshots `evidence/library-all-games-*` (header "Steam 8") and `evidence/library-steam-selected-gray-*` (no header).
- Result: pass. Headers only in All Games; a single source, Favorites or a console has none. Console games use square covers.

### Covers for PC games / Steam game offline
- Check: test `CoverTests.offlineFromCache`, `steamCacheLayouts`.
- Result: pass. Steam's own `appcache/librarycache` is read first in its three layouts; a cover fetched once from `shared.fastly.steamstatic.com` is kept in `~/Library/Caches/Cartouche/covers` and shows with every request failing.

### Covers for PC games / User override
- Check: test `CoverTests.userOverride`.
- Result: pass. A dropped image (confirmation "Use this image as the cover of …?") or Change Cover… is copied into `covers/` in the data folder, wins over Steam's art, survives a library reload and a relaunch, and Use the Original Cover goes back.

### Covers for PC games / Nothing found
- Check: test `CoverTests.nothingFound`, `drawnRenders`; screenshot `evidence/cover-drawn-*.png`.
- Result: pass. Offline, a 404 or an error page served as 200 all end on the cover drawn from the name (and the exe icon when the game has one) on a plain background; nothing is cached from a non-image answer.

## Task 1.1 blocked

The export of the owned games from Steam's UI needs a channel from the injected page code to the app. `docs/TRD.md` lists it as not decided ("file or local route"). I wrote one (the page sending the JSON as loopback requests that `hook_webpatch.c` turns into `steam-library.json`), and the session's safety check refused it: any page Steam renders could reach those loopback paths and write that file. I reverted it; no dylib file changes in this branch. What is in place:

- The app reads `~/Library/Application Support/Cartouche/steam-library.json` (format in `SteamLibraryImport.swift`, `SteamExport`, version 1) and reloads within 2 s of a change.
- Without it, the installed games, play data, collections and account come from Steam's files.

The maintainer or orchestrator needs to pick a channel the page alone can use (for example a WebUI route registered by the dylib, which only Steam's own transport reaches) before 1.1 can be built.

## Choices made without the maintainer (to review)

- The old Status, Prefixes and Prefix Backups panes moved to a "Steam Play Setup" window (Setup menu, ⌘1 to ⌘3, and a button in Settings > Compatibility). The library is the main window. Rejected: putting them in the sidebar, which the mockup does not have.
- Settings has six tabs: the five of task 3.2 plus Consoles (P12's `ConsolesSettingsView`). Beta updates (P9) sit in General, as in the mockup. Agents and Controllers come with P11 and P15.
- Store sign-in (P10), Add Games flows (P6, P13) and Your Play (P8) are not built: their buttons are present but disabled, with one sentence saying they come in a later version.
- Sidebar icons are SF Symbols, not store logos.
- Per-game Runner, Graphics and Translation are saved in `library.json`; writing them to Steam is P3's.
- The panel uses the 2026-10-19 fixture; the spec names 2026-10-18, for which there is no fixture.
- Play, Install, Verify Files, Show in Steam and Uninstall go through Steam's `steam://` links.

## Manual checks for the maintainer

- M1. Run `out/Cartouche.app` on macOS 15 and on macOS 26: every screen above, light and dark, no missing control.
- M2. In the running app: Reduce Motion on (no tilt, no springs), Reduce Transparency on, ⌘D, ⌘I, ⌘↩, ⌘F and ⌘, with a game selected; the status item menu.
- M3. On a test account without Steam: Download Steam, then Install with Homebrew, then Locate Steam….
- M4. Real Steam closed and running: covers from Steam's cache, and the toolbar account name.
