# Evidence: p15-controls

Branch `phase/p15-controls`, from main 9b6714e, with main merged (P7 activity, P8 performance, P16 standalone emulators). Machine: Apple silicon, macOS 27.0, Swift 6.4.

How the tests run:

- No real controller, Wine, RetroArch, Steam, or macOS permission is touched. Controllers are simulated (`FakeControllerSource`, `FakePad`), TCC answers come from `FakeTCC`, the frontmost app from `FakeFocus`, posted events go to `RecordingInputPoster`/`FakeTap`, and every file lands in scratch folders under the test's temporary directory. A stand-in `wine` shell script records the launcher's calls and environment instead of running anything.
- There is no XCUITest target; the "UI tests" drive the same view models the views bind to and render each view offscreen (`UIHost`, `windowSnapshot`), reading the text back by OCR. PNGs go to `evidence/` when `CARTOUCHE_SNAPSHOTS` is set: `CARTOUCHE_SNAPSHOTS=openspec/changes/p15-controls/evidence swift test --filter "Controls screens|Couch mode"`.
- Live-RetroArch tests stay disabled unless `CARTOUCHE_RETROARCH` and `CARTOUCHE_TEST_CORE` name real binaries; they skip cleanly here.

## Tests

| Suite | Result |
|---|---|
| `cd app && swift test --no-parallel` (in the implementer's sandbox) | 1009 tests in 143 suites. Every Controls logic suite passes: "Controller status" (5), "Controller layouts for Wine games" (8), "Console layouts as RetroArch remap files" (5 run, the live-RetroArch one skips), "Mac keyboard and mouse in Wine games" (5), "Play with a controller and key remapping" (6), "Couch mode" (4). Every failure is environmental, none is in Controls code: the baseline tests that need the staged payload ("This build of Cartouche carries no components at all") or reach the network ("Cartouche could not reach Valve's servers", hdiutil, `~/Library` read-only), plus `VNRecognizeTextRequest` throwing `_GenericObjCError nilError` and windows clamping to 80×80, so no drawn text can be read back. The same limits fail the pre-existing UI suites (LibraryWindow, ConsoleImport, BIOSLook, ActivityQuit, StandaloneConsole…) the same way; the orchestrator's run outside the sandbox covers them. |
| `sh dylib/tests/settingscheck.sh dylib/feats/compat_run.sh` (run by `MacKeyboardTests.runScript`) | pass, "the game's keyboard options join the import, other lines are dropped" |
| `l10ncheck` equivalent (`dylib/tests/l10ncheck.py` on the Release stringsdata) | 1106 strings, all translated for zh-Hans and it, except the 1 string main already leaves in English |
| `openspec validate p15-controls --strict` | valid |

In this sandbox the "Controls screens" tests cannot run their OCR step, so the `evidence/*.png` screenshots named below are produced by running them outside the sandbox with `CARTOUCHE_SNAPSHOTS=openspec/changes/p15-controls/evidence` (they render the window first, then read it).

New suites in `app/Tests/NotProtonAppTests/`: "Controller status" (`ControllerMonitorTests.swift`), "Controller layouts for Wine games" (`SDLMappingTests.swift`), "Console layouts as RetroArch remap files" (`RetroArchRemapTests.swift`), "Mac keyboard and mouse in Wine games" (`MacKeyboardTests.swift`), "Play with a controller and key remapping" (`KeyboardPlayTests.swift`), "Couch mode" (`CouchModeTests.swift`), "Controls screens" (`ControlsUITests.swift`). No test was removed or skipped.

## Scenarios

### Controller status / DualSense
- Check: test `ControllerMonitorTests` "A DualSense connecting shows by name with its battery, well within 2 seconds"; test `ControlsUITests.dualSense`; screenshots `evidence/controllers-settings-light.png`, `evidence/controllers-settings-dark.png`, `evidence/controls-panel-dualsense-light.png`.
- Result: pass on the model. A simulated DualSense connect makes Settings > Controllers list "DualSense Wireless Controller" with "80%" and the game panel show "DualSense" with "Battery 80%", read back off the drawn windows well under 2 seconds after the connect. Battery changes and disconnections follow; a wired controller reads "Connected" (`ControllerMonitorTests` second test).
- Not covered here: a real DualSense over Bluetooth. Manual check M1.

### Remapping per game / Wine game remap
- Check: test `SDLMappingTests.swapCrossCircle` (the mapping's `a:b1,b:b0`); test `SDLMappingTests.launchEnvironment` (a real `sh` run of the game's launcher against a stand-in wine: `SDL_GAMECONTROLLERCONFIG` equals the written mapping); test `SDLMappingTests.olderLauncher` (a launcher written before Controls gets the block once, before `exec`); test `ControlsUITests.wineGame`; screenshot `evidence/controls-wine-cross-circle-light.png`.
- Result: pass for the mechanism. Swapping Cross and Circle for an installer game writes `installs/hades/controller.sdl` (every line a valid `SDL_GameControllerAddMapping` entry: 32-hex GUID, `*` name, `key:[+-]bN|aN` pairs), the launcher exports it into the game's environment before exec, and going back to Default removes the file so the next launch has no mapping.
- Not covered here: the game itself reacting to Circle where it reacted to Cross, which needs real Wine and a controller. Manual check M2. Task 2.1 stays unticked for that reason.

### Remapping per game / Steam game
- Check: test `ControlsUITests.steamGame`; test `SDLMappingTests.handler`; test `MacKeyboardTests.steamGame`; screenshot `evidence/controls-steam-game-light.png`, `evidence/controls-steam-game-dark.png`.
- Result: pass. Customize on a Steam game shows "Steam Input handles this game" with Open in Steam; Open in Steam opens `steam://nav/games/details/1245620`; dismissing leaves the library folders and `controls.json` untouched (no SDL file, no remap file, no permission asked). The only file a Steam game can get is `setups/<appid>.keyboard`, and only once a keyboard option was changed.

### Remapping per game / Console game
- Check: test `RetroArchRemapTests.render` (the `.rmp` contents: `input_player1_btn_b = "8"`, `input_player1_btn_a = "0"`); test `RetroArchRemapTests.writesAndRemoves` (one file per SNES core folder, removed on Default; a user-saved `.rmp` is left alone); test `RetroArchRemapTests.retroArchLoadsIt` (the pinned RetroArch logs "Game-specific remap found" for the file — gated on `CARTOUCHE_RETROARCH`, skipped here); test `ControlsUITests.consoleGame`; screenshot `evidence/controls-snes-swap-ab-light.png`.
- Result: pass for the file and the UI. The live-RetroArch check is written and gated like P13's other live tests — it runs once `CARTOUCHE_RETROARCH` and `CARTOUCHE_TEST_CORE` name real binaries, and skips cleanly until then. Picking Swap A/B in the sheet writes `remaps/<core>/Super Mario World (USA).rmp` under each SNES core's folder, so the next launch on any SNES core picks it up.

### Mac keyboard and mouse in Wine games / Command as Control
- Check: test `MacKeyboardTests.registryFile` (all six Mac Driver values, `y`/`n`, CRLF); test `MacKeyboardTests.installerGame` (`reg import C:\cartouche-keyboard.reg` runs before the game, once per change, imported again with `n` when turned back off); test `MacKeyboardTests.steamGame` (a Steam game's options go to `setups/<appid>.keyboard`); test `MacKeyboardTests.runScript` (`settingscheck.sh`: `compat_run.sh` merges only the six values into the prefix import, ignores other lines, other app ids and symlinks).
- Result: pass for the mechanism. Turning Command acts as Control on writes `keyboard.reg` beside the game's launcher; the launcher imports it into that game's prefix once per change. A Steam game gets `setups/1145360.keyboard`, which `compat_run.sh` reads into its own settings import for that app id's prefix.
- Not covered here: Command-C reaching the game as Control-C inside real Wine. Manual check M3. Task 3.1 stays unticked for that reason.

### Controller for keyboard-only games / Only while the game is frontmost
- Check: test `KeyboardPlayTests` "Only while the game is frontmost: away from it nothing is posted until it is in front again"; test `KeyboardPlayTests` "Another game in front counts as away"; test `KeyboardPlayTests` "A Wine game's process is told apart by its prefix, a Steam game by its app id"; test `ControlsUITests.accessibility`; screenshot `evidence/controls-keyboard-tab-light.png`.
- Result: pass on the model. With the option on and Accessibility granted, a pressed pad button posts its key while the game is frontmost; moving the front to another app (or another game) posts nothing until the game is in front again. Without the grant nothing runs for the game; the option asks for Accessibility with the explanation first, exactly once.
- The real grant and a real posted event reaching a game are the maintainer's Accessibility row in P17's permission matrix (live, no relaunch).

### Couch mode / Controller only
- Check: test `CouchModeTests` "From launch to Play with the controller only: pick a game, open it, play it"; test `ControlsUITests.couchToPlay`; screenshots `evidence/couch-1-launch-light.png` through `evidence/couch-4-played-light.png`.
- Result: pass on the model. From a fresh launch with only pad input: D-pad moves the ring across the grid, South opens the picked game's panel and puts the ring on Play, a second South presses it and the run goes out (`steam://rungameid/…` in the test). The ring is visible at every step; held directions repeat after a pause, edges stop the ring, L1/R1 change the sidebar list, and nothing happens with couch mode off or no controller.
- A real pad end to end is part of manual check M1's session.

## Manual checks for the maintainer

- M1. Controller status with a real pad: pair a DualSense over Bluetooth. Within 2 seconds Settings > Controllers and an open game panel show "DualSense" with a battery percentage. While it is connected, turn on couch mode and go from the library to a running game with the pad only.
- M2. Wine game remap end to end (task 2.1): in Controls for a non-Steam Wine game, swap Cross and Circle, launch the game (a controller test app, e.g. a gamepad viewer, is enough). The game reacts to Circle where it reacted to Cross. `controller.sdl` beside the launcher holds the mapping, and `ps eww <wine pid> | tr ' ' '\n' | grep SDL_GAMECONTROLLERCONFIG` shows it in the environment.
- M3. Command as Control end to end (task 3.1): turn on "Command acts as Control" for a Wine game, launch it, and press Command-C in a text field of the game. The game receives Control-C (copy). The prefix's `HKCU\Software\Wine\Mac Driver` shows `LeftCommandIsCtrl`/`RightCommandIsCtrl` = `y` after the import.
