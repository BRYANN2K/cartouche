# Regressions

One line per bug fixed since 0.1.2, with the test that fails if it comes back.
Swift tests are in `app/Tests/NotProtonAppTests/`, named by file and `@Test` title.
"Source text" means the test reads the code instead of running it: it catches a revert, not a new way to break it.

Add a line with every fix. A fix without a test says why under "Gaps".

## 0.2.0-beta1 and after

| Bug (commit) | Test | Kind |
|---|---|---|
| Uninstalling an Epic, GOG or Amazon game trashed the folder the user picked (#8, c674a120) | StoreUninstallTests: "Uninstall trashes only game, pfx and logs; the user's other files stay", "A picked folder gets the game in its own subfolder", "Home, its standard folders and volume roots are never touched" | behaviour |
| Store center deleted a record's folder outright (c674a120) | StoreUninstallTests: "The store center no longer deletes a record's folder outright" | source text |
| Runner update: Steam's stale mapping took games back to the old build (9d1d06ad) | RunnerUpdateTests: "Steam's stale mapping to the build a game was updated from never takes it back" | behaviour (`isDowngrade`), call site source text |
| The in-game menu minimized a fullscreen game; it must open on the game's Space (544fd310, e8274047, b3b6abaf) | OverlayTests: "Fullscreen game: the panel shows before Cartouche activates, and the app's windows wait for the user to come back"; GameRestoreTests: "Runs the helper in the game's own Wine with the game's exe name" | behaviour, macOS focus stubbed |
| The library showed behind the menu when Cartouche hid itself at launch (f2c12fa8) | OverlayTests: "Cartouche hidden at launch: its windows leave before activation unhides it, and it hides again after", "Windowed game: the app's windows come back behind the game as soon as the menu closes"; OverlayFrameTests | behaviour |
| The FPS HUD showed twice on a game that already had Cartouche's HUD (488a93f9) | OverlayTests: "A game whose metrics block exists already draws the HUD: the menu never adds a second one" (added here); LaunchSafetyTests: "Without the library in the game the HUD is Cartouche's own panel; with it, the game's" (assertion corrected here) | behaviour |
| EA app sign-in page stayed black (9471edbb) | LauncherStoreTests: "The launcher's own prefix, exe, log and the vendor's install flags", "EA's install is the real recipe: …" | behaviour |
| Ubisoft launcher painted nothing (98292bec) | LauncherStoreTests: "The launcher's own prefix, exe, log and the vendor's install flags"; LauncherAdapterTests: "Ubisoft: install opens uplay://install, …" | behaviour |
| Games started by the Ubisoft launcher crashed without the graphics backend (a7b50aea) | LauncherStoreTests: "open() hands the launcher's env the game's graphics backend; none without one" | behaviour |
| EA install hung on pipes its children kept open (332a3c70) | StoreClientTests: "run() settles on the process's exit, not on the EOF of pipes a child keeps open"; LauncherStoreTests: "EA's install is the real recipe: …" | behaviour |
| EA protocol and service registry keys (332a3c70) | GoldenTests: "The registry writes a store or a game's settings make in a prefix" (`Goldens/registry/ea-reg-add.tsv`) | golden |
| At 800 pt the toolbar pushed its controls into the overflow (14b996ec) | ToolbarBallsTests: "At the window's smallest width the title gives way, …" | layout numbers |
| Background Apps opened by itself when Cartouche came back to the front (d3449860) | BackgroundAppsTests: "The app's activation handler never reaches Background Apps, …" (added here), "Coming back to the app offers nothing: …" | source text |
| Background Apps alert threshold defaults to 60 %, a chosen one is kept | ResourceMonitorTests: "The default threshold is 60 %, CPU and GPU", "Thresholds survive a relaunch" | behaviour |
| The beta's built-in protected list resets on update, a chosen list stays | ResourceMonitorTests: "A stored list equal to the beta's resets; a chosen list stays" | behaviour |
| Steam read as the "Current game" | ResourceMonitorTests: "Steam is the launcher: never the game, never quittable, its processes one row" | behaviour |
| The "All" tab did not add up to the Mac's CPU | ResourceMonitorTests: "In « Tout », the rows and « Système et autres » add up to the Mac's CPU" | behaviour |
| Keychain prompted at launch and once per store | StoreVaultTests (whole suite); StoreSignInTests: "The Keychain item is a generic password …"; AgentTests: "Launch does not touch the secret store; …" | behaviour |
| Outside FPS counter on anti-cheat games stayed dead after a failure; a refused Screen Recording said nothing | OverlayTests: "A counter that found no window yet is retried, not kept dead", "A stream that stops is replaced", "A refused « Autoriser… » says so instead of staying silent" | behaviour |
| Sidebar: Steam alone by default, connected stores stay | SidebarStoresTests: "Fresh install: Steam alone, …", "Update: a store connected before this version stays, …"; AddMenuTests | behaviour |
| Metal shader cache lost with the Cartouche Wine rename (277e388a) | MetalCacheMigrationTests | behaviour |

## 0.1.2

| Bug | Test | Kind |
|---|---|---|
| Accept and Install failed when Steam no longer served the license ("No eula for app") | `dylib/tests/steam-install.js`, scenario `eulaGone` | behaviour (Node, not app/Tests) |
| A failed install left Steam's install window open, so retries failed with "another-install" | `dylib/tests/steam-install.js`, scenarios `appError:5`, `busyApp:43` | behaviour (Node, not app/Tests) |
| Download progress lagged minutes behind Steam | SteamDownloadLiveTests: "Live bytes from Steam's overview replace the manifest's stale count while they are fresh", … | behaviour |
| A download Steam set aside showed "Steam reported error 4" | SteamDownloadLiveTests: "A download Steam set aside for another one waits in the queue instead of failing" | behaviour |

## 0.1.1

| Bug | Test | Kind |
|---|---|---|
| A game without D3DMetal fell back to wined3d (Raft "Failed to initialize graphics") | GraphicsFallbackTests: "Only the pinned backends not yet installed are fetched with Cartouche Wine", "Once DXMT is in, Cartouche Wine under Rosetta picks it before wined3d" | behaviour |
| A D3DMetal image already open in Finder failed with "Resource busy" | GraphicsFallbackTests: "Its Finder volume is reused instead of a second attach that fails with Resource busy" | behaviour |
| No word when Apple publishes a newer D3DMetal | GraphicsFallbackTests: "A newer D3DMetal is named only when the newest copy on this Mac is older" | behaviour |

## Whole-output guards

These catch an accidental change in what Cartouche writes, whatever bug caused it.

- Goldens (`GoldenTests`, `Goldens/`): installer launch scripts, Steam `tools` and `backend-tools`, runner manifest read and write, registry writes, What's New, CHANGELOG release notes, shared memory block layout.
- `compatibilitytool.vdf` and `toolmanifest.vdf`: `make compatcheck` writes them from the `tools` goldens and compares with `Goldens/steam-tools/vdf.txt`.
- Snapshots (`ScreenSnapshotTests`, `Snapshots/`): library grid, game panel, store page, Settings > Runners, Background Apps, in-game menu, HUD.

`CARTOUCHE_UPDATE_GOLDENS=1` rewrites the goldens (Swift and compatcheck), `CARTOUCHE_UPDATE_SNAPSHOTS=1` the snapshots.

## Gaps

- The fullscreen minimize fix is checked through stand-ins for macOS activation: only a real game shows macOS keeps it unminimized.
- Background Apps on activation is source text only: the SwiftUI scene does not run in tests.
- The 0.1.2 Steam install fixes are covered by the Node test of the injected script, not by app/Tests.
