# Evidence: p13-console-library

Branch `phase/p13-console-library`, from main 797fb2b, with main merged before the final checks (09f5e80: P3, P6; then P18). Machine: Apple silicon, macOS 27.0, Xcode 27.0 (Xcode-beta.app), Swift 6.4. RetroArch pinned at `ed3187ec8e1fe55145366789718dc77f34abaeca`.

How console tests run:

- Game files are synthetic homebrew written by the tests: 32 KiB SNES and Game Boy cartridges with a named header, PlayStation data tracks whose system file boots a made-up serial (`SLUS_999.0x`), and the RetroArchKit test cartridge (three colour bytes and a title). No byte of any published game is used.
- The libretro database is `retroarch/Tests/RetroArchKitTests/Fixtures/database/rows.json`: rows recorded from libretro-database `rdb/` (master, 2026-10-19), Super Metroid, A Link to the Past, Crash Bandicoot and Metal Gear Solid among them, plus rows for the homebrew files. Their checksums were computed with Python's `zlib` and `hashlib`, apart from Cartouche's own CRC32. Tests write them as `.rdb` files with libretro-db's format.
- The buildbot, libretro-database and libretro-thumbnails are stood in for by a URL protocol on `*.test` hosts (`StubWeb`), so no test reaches the network, except `withTheRealDatabaseACartridgeIsNamedWithinTwoSeconds` with `CARTOUCHE_NETWORK_TESTS=1`.
- Real RetroArch runs use the rig (`make retroarch-rig retroarch-testcore`, P12's approach): the pinned commit built with `./configure`, the test core, `CARTOUCHE_RETROARCH_VIDEO=gl` for a window, pictures and shaders. Each run gets `HOME` and `CFFIXED_USER_HOME` in its scratch folder and Cartouche's own `-c`. After the final runs, `~/Documents/RetroArch` and `~/Library/Application Support/RetroArch` do not exist (see "Found on the way").
- Screenshots: `evidence/`, written by the tests with `CARTOUCHE_SNAPSHOTS`. They are offscreen captures: switches, the default button tint and some text in scroll views in dark mode do not draw as on screen (the same limit as P5's evidence).

## Tests

| Suite | Before (main 797fb2b, run here) | After |
|---|---|---|
| `make -s app-tests` | 785 tests in 95 suites, 34 fail (43 issues), all needing the staged payload | after merging main with P18: 900 tests in 119 suites, the same 34 fail (43 issues); `diff` of the failing names with the 797fb2b baseline is empty |
| App console suites with the rig and `gl` (`ContinueFromTests`, `BIOSLookTests`, `ActivityQuitTests`, `ConsoleImportTests`) | new | 19 tests with `RetroArchHomeTests` and `GameFolderTests`, all pass (4 skip without the rig) |
| `make -s retroarch-tests`, no RetroArch | 67 tests in 9 suites, all pass | 99 tests in 14 suites, all pass |
| `make retroarch-tests` with the rig, test core and `gl` | 67 pass (P12 evidence) | 97 tests, all pass, live tool contract included |
| `CARTOUCHE_NETWORK_TESTS=1`, real libretro SNES database | new | pass |
| Hermetic suites of `app.yml` (19, `packagingcheck` included), `mincheck`, `runcheck`, `scriptcheck` | pass | pass (`runcheck` and `scriptcheck` skip: no shellcheck here) |
| `make -s redistscan`, `make -s retroarch-scancheck` | pass | pass |
| `make -s -o app-payload app && make -s l10ncheck` | 730 strings | 999 strings after the merges, all translated for zh-Hans and it, except the one string main already leaves in English |
| `make -s retroarch-l10ncheck` | 32 strings | 36 strings, all translated |
| `openspec validate --all --strict` | – | 19 passed |

## Scenarios

### Consoles the user chose / Add two consoles
- Check: test `ConsoleSidebarTests.addTwoConsoles` ("Add two consoles: + opens Add Consoles, NES and Game Boy join the sidebar with their two cores and no other"); screenshots `evidence/add-consoles-light.png`, `-dark.png`, `evidence/sidebar-consoles-light.png`, `-dark.png`.
- Result: pass. The + next to Consoles sets `showAddConsoles` (not the Add Games sheet). With NES and Game Boy picked the button reads "Add 2 Consoles". After Add: sidebar consoles `["nes", "gb"]`, read back from the drawn sidebar as "Nintendo Entertainment System" and "Game Boy"; cores folder `["nestopia_libretro.dylib", "sameboy_libretro.dylib"]`; the only core downloads are `/nightly/nestopia_libretro.dylib.zip` and `/nightly/sameboy_libretro.dylib.zip`. Reopened, the sheet marks both "Added".

### Consoles the user chose / Games already found are suggested
- Check: test `GameFolderTests.foundGamesAreSuggested`; screenshots `evidence/add-consoles-found-light.png`, `-dark.png`, `evidence/settings-game-folders-*.png`.
- Result: pass. A watched folder holds four Game Boy homebrew cartridges; Game Boy is not added. After the scan `found == ["gb": 4]`, no game enters the library, and the Game Boy tile reads "4 games found". Settings > Library shows the folder as "Watched. 4 games found". Adding Game Boy then brings the four in, named from the database.

### Consoles the user chose / Remove a console
- Check: test `ConsoleSidebarTests.removeConsole`, plus `removeWording`; screenshot `evidence/sidebar-after-remove-light.png`.
- Result: pass. The right-click menu on PlayStation offers "Add PlayStation Games…" and "Remove PlayStation (2 games stay on disk)". Remove: the sidebar holds `["snes"]`, selection goes back to All Games, the cores folder holds only `snes9x_libretro.dylib`, and the two games' four files (`.cue` and `.bin`) exist with unchanged SHA-256. Adding PlayStation again brings its two games back with their play data.

### Adding games by checksum / Known cartridge
- Check: tests `ConsoleImportTests.knownCartridge` (the + sheet, drawn), `IdentifierTests.aKnownCartridgeIsNamedByItsChecksumWithinTwoSeconds`, `recordedRowsNameTheRealGames`, `withTheRealDatabaseACartridgeIsNamedWithinTwoSeconds` (network); screenshot `evidence/import-known-light.png`.
- Result: pass for the mechanism, with one maintainer step.
  - A homebrew SNES cartridge dropped on the sheet is listed as "Cartouche Homebrew" with "Super Nintendo, checksum match" 0.23 s after the drop (limit 2 s). With a 512-byte copier header it is the same game.
  - The recorded row for CRC32 `d63ed5f8` is "Super Metroid (Japan, USA) (En,Ja)", shown as "Super Metroid", console Super Nintendo. Against the whole real SNES database (downloaded), a 3 MiB cartridge is checked in 0.39 s, database read included.
  - Maintainer step: drop your own No-Intro dump of Super Metroid on Add Games > Console Games. Pass when the row reads "Super Metroid" and "Super Nintendo, checksum match" within 2 seconds.

### Adding games by checksum / Disc image
- Check: tests `ConsoleImportTests.discImage`, `IdentifierTests.aDiscIsKnownByItsSerial`, `aMultiDiscSetWithAnM3UIsOneGame`; screenshot `evidence/import-discs-light.png`.
- Result: pass for the mechanism, with one maintainer step. A `.cue` with its `.bin` is read as RetroArch's scanner reads it (`SLUS_999.01` becomes `SLUS-99901`) and listed as "Cartouche Test Disc", "PlayStation, disc ID"; its `.bin` is not listed on its own. A folder with `Saga.m3u` and two discs gives one game, "Cartouche Test Saga", 2 discs, identified by the first disc's ID; the panel then offers Disc 1 and 2. Without a serial, the SHA-1 of the data track is matched against Redump's rows (code path not covered by a test). The recorded rows find Crash Bandicoot by `SCUS-94900` and Metal Gear Solid disc 1 by `SLUS-00594`.
  - Maintainer step: drop your own Redump `.cue`/`.bin` of a PlayStation game, then a two-disc set with an `.m3u`. Pass when the first shows "PlayStation, disc ID" and the set is one row.

### Adding games by checksum / Unknown file
- Check: tests `ConsoleImportTests.unknownFile`, `IdentifierTests.anUnknownHomebrewAsksForAConsole`; screenshots `evidence/import-identified-light.png`, `-dark.png`.
- Result: pass. `my_homebrew.gba` with no database row is listed as "Not recognized" with a "Choose console…" picker (Game Boy Advance offered first). The button reads "Add 1 Game" and `games` holds only the recognized cartridge. Once Game Boy Advance is picked it reads "Add 2 Games"; Add puts it in Game Boy Advance, marked as chosen by the user.

### Adding games by checksum / Watched folder
- Check: test `GameFolderTests.copiedGameAppears` (FSEvents, no sheet).
- Result: pass. With Game Boy added and a watched folder, `quest.gb` copied in from elsewhere appears in Game Boy as "Cartouche Quest" 1.07 s after the copy (limit 10 s). `addGames` and `showAddConsoles` stay unset. A file the database does not know stays out.

### Adding games by checksum / Back and forth in the + sheet
- Check: test `ConsoleImportTests.backAndForth`; screenshots `evidence/add-games-console-first-light.png`, `evidence/add-games-windows-first-light.png`.
- Result: pass. Since P6, Windows Game is its own install sheet, so the + sheet's two kinds are two sheets that hand over to each other; each has the Windows Game / Console Games picker. Kind switches go through each sheet's own segmented control (an AppKit `NSSegmentedControl`, selected and its action sent as a click does).
  - Console Games shows "Drop files or a folder here". From the identification step, Back (the method the button calls) returns to that step with no row and nothing checking.
  - Windows Game in its picker resets the console flow, closes the sheet and asks for the install sheet (`addGames` goes to nil, then `.windows`, which P6's host turns into its sheet). The install sheet shows its first step, "Install a Windows Game", with the picker.
  - Console Games in the install sheet's picker asks for Add Games with Console Games again (`addGames == .consoles`), which opens on the drop step with nothing checking. A new drop then identifies at once and Add is enabled.
  - SwiftUI draws its buttons without AppKit controls, so Back and Choose… are reached through the model the buttons call, not a click.

### Covers / Offline after first view
- Check: tests `ConsoleCoverTests.offlineAfterFirstView`, `squareCards`, `ThumbnailTests` (escaping, cache, 404); screenshots `evidence/console-card-offline-light.png`, `evidence/console-square-landscape-light.png`, `-portrait-light.png`.
- Result: pass. The first view fetches `Named_Boxarts` and `Named_Snaps` for "Legend of Zelda, The - A Link to the Past (USA)" at `/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/Named_Boxarts/Legend%20of%20Zelda%2C%20The%20-%20A%20Link%20to%20the%20Past%20%28USA%29.png` (parentheses, commas and spaces escaped; `&` becomes `_` as the project names files). Offline, a new cover store shows the same two files from the cache with no request, and the card draws the cached box. A landscape and a portrait box both sit whole in the square card.

### Console game panel / Resume from a state
- Check: tests `ContinueFromTests.resumeOnRetroArch` (app, rig, `gl`), `PlayerIntegrationTests.resumeFromSlotThreeShowsThatMoment` (RetroArchKit, rig, `gl`), `ContinueFromTests.slotsGoToThePlayer`; screenshots `evidence/continue-from-live-light.png` (the panel with RetroArch's own state pictures), `evidence/p13-slot3-picture.png`, `evidence/p13-slot3-resumed.png`, `evidence/console-panel-light.png`, `-dark.png`.
- Result: pass. The test core draws a white bar that moves one pixel a frame. Slot 3 is saved with the bar at x=65; Cartouche quits; Continue From lists "Auto" and "Slot 3" with RetroArch's pictures. Clicking Slot 3 starts RetroArch, loads the game and `STATE load 3`: the game shows the bar at x=68 (3 frames later, before the pause), and the slot's own picture has it at x=65. RetroArchKit's own run: saved at 17, resumed at 19.

### Console game panel / Missing BIOS blocks Play
- Check: test `BIOSLookTests.missingBIOS`; screenshots `evidence/console-panel-bios-missing-light.png`, `-dark.png`.
- Result: pass. A PlayStation game without a BIOS: the panel reads "scph5501.bin is missing" and "Dump it from your own console, then put it in the BIOS folder.", with Show BIOS Folder; Play is disabled, and `play` refuses with that message (the player receives nothing). The drawn panel has no link and no "download". With the user's own file in the BIOS folder matching the `.info` MD5, the warning goes and Play starts the game.

### Console game panel / Look applies live
- Check: tests `BIOSLookTests.lookLive` (panel), `BIOSLookTests.lookOnRetroArch` (app, rig, `gl`), `PlayerIntegrationTests.lookAppliesWithinASecond`; screenshots `evidence/console-panel-crt-light.png`, `evidence/retroarch-crt-from-panel.png`, `evidence/p13-look-original.png`, `evidence/p13-look-crt.png`.
- Result: pass. While playing, Look set to CRT is sent to RetroArch at once; `SET_SHADER` answers once the preset is on screen: 0.004 s from the panel, 0.03 s in RetroArchKit (limit 1 s). RetroArch's screen then has scanlines: the brightness spread down one column goes from 0 to 47–65. The panel's picture takes the same look: its row spread goes from 0.0 to 0.24. Not playing, the look is kept and sent with the next start. Cartouche writes its own CRT and LCD presets, in slang (Metal) and GLSL (OpenGL), and falls back from one to the other when the driver refuses a kind.

### Launch and quit / Quit from Cartouche
- Check: tests `ActivityQuitTests.quitOnRetroArch` (rig), `quit`, `launch`, `reduceMotion`, `endedByItself`, `PlayerIntegrationTests.quitWritesTheAutoStateAndReportsTheTimePlayed`; screenshots `evidence/activity-slot-playing-light.png`, `-dark.png`, `evidence/crt-power-on-light.png`.
- Result: pass. Play shows the CRT power-on (the game's screenshot opening from a line, with scanlines; not shown with Reduce Motion), then the activity slot reads "Playing", the game's name and Quit. Quit closes RetroArch's pipe: it quits through its own Quit path in 0.03 s and writes `Test Cart.state.auto` with `Test Cart.state.auto.png`; Continue From then leads with Auto; play time grows by the session (1.56 s on RetroArch, 1.22 s with the stand-in); the slot goes. RetroArch closed from its own window ends the session too, with its play time. Resume afterwards loads the auto state.

## Found on the way

- Run-ahead with RetroArch's second instance (its default) does not follow a loaded state: the game showed a frame about 2 s away from Slot 3. Cartouche now sets `run_ahead_secondary_instance = false`, and Slot 3 resumes where it was saved with Lower input lag on.
- The pinned RetroArch makes `~/Documents/RetroArch/playlists/builtin` (and `~/Library/Application Support/RetroArch/config` for `--version`) in the real home whatever `HOME` says: `config_set_defaults` makes the default playlist folder before any config is read, and macOS RetroArch finds `~` through Foundation, which reads `CFFIXED_USER_HOME`, not `HOME`. Fixed: `ConsoleLauncher` now starts RetroArch with `HOME` and `CFFIXED_USER_HOME` both set to Cartouche's `<root>/home`, Settings > Consoles probes builds the same way, and `check-retroarch.sh` runs them in a scratch home. Tests: `PlayerTests.retroArchsHomeIsCartouchesWhateverTheUsersIs`; on the rig, `PlayerIntegrationTests.theUsersHomeIsNeverRetroArchsHome` and `RetroArchHomeTests.nothingInTheUsersHome` start RetroArch through the launcher and through the app's own path (default probe, Settings' launcher, console center), from an environment whose `HOME` and `CFFIXED_USER_HOME` are a scratch stand-in for the user's home: the stand-in stays empty, and `Documents/RetroArch` appears under Cartouche's `<root>/home` instead. After all final runs, `~/Documents/RetroArch` and `~/Library/Application Support/RetroArch` do not exist.
- Cartouche quitting while a console game runs now quits RetroArch first (its auto state is written) and keeps the session's play time: test `RetroArchHomeTests.quitWithCartouche`.
- P18's game folders (Settings > Library, onboarding) are the folders watched; Settings > Library shows each folder's count and the "Add new games automatically" switch in P18's section.

## Not done here

- Task 5.1: APPFLOW and DESIGN are the docs agent's.
- macOS 15 runs and Reduce Transparency are for the maintainer; Reduce Motion is covered by `ActivityQuitTests.reduceMotion`.
