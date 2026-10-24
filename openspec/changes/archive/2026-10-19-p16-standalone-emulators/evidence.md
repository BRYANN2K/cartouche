# Evidence: p16-standalone-emulators

Branch `phase/p16-standalone-emulators`, from main da94105, with main e802c33 (P8) merged before the final checks. Machine: Apple silicon, macOS 27.0, Swift 6.4.

How the emulator tests run:

- No real emulator is read, started or changed. Each test makes fake app bundles in a scratch folder (`FakeEmulators.app` in RetroArchKit's tests, `FakeEmulatorApp` in the app's). A fake app carries the `Info.plist` the real app ships (identifier, executable, version) and a `/bin/sh` executable. The script writes the arguments it got, then runs until a quit file appears or it gets SIGTERM.
- The app's `ConsoleScene` looks for emulators in its own `Applications` folder, never in `/Applications` or `~/Applications`. Emulator choices and logs go to the scene's Cartouche folder. Nothing is written under the real `~/Documents` or `~/Library`.
- The game file is a GameCube homebrew DOL written by the test: a DOL header and two PowerPC instructions (`li r3,0; b .`). It contains no byte of any published game.
- Facts about each emulator (bundle IDs, executables, arguments, settings folders, buildbot cores) are in `docs/research/standalone-emulators.md`, with sources.
- Screenshots are in `evidence/`. They are offscreen captures, so in dark mode some controls draw as on a light window. P5 and P13 have the same limit.

## Tests

| Suite | Before (main da94105, run here) | After (merged with main e802c33) |
|---|---|---|
| `make -s app-tests` | 900 tests in 119 suites, 34 fail (43 issues), all needing the staged payload | 928 tests in 125 suites, the same 34 fail (43 issues). `diff` of the failing names with the baseline is empty. |
| `make -s retroarch-tests` | 99 tests in 14 suites, all pass | 117 tests in 18 suites, all pass |
| `make -s installer-tests` (installer `swift test`) | not run before (no installer file changed) | 73 tests in 11 suites, all pass |
| Hermetic suites of `app.yml` (19) and `packagingcheck` | pass | all pass |
| `sh packaging/redist-scan.sh` on a `git archive HEAD` export | pass | pass |
| `make -s -o app-payload app && make -s l10ncheck` | not run before; merged main has 1012 (1018 minus the 6 added) | 1018 strings, all translated for zh-Hans and it, except the one string main already leaves in English |
| `make -s retroarch-l10ncheck` | 36 strings (P13 evidence) | 45 strings, all translated |
| `openspec validate --all --strict` | – | pass |

Existing tests changed, and why:

- `CatalogTests.makersGroupTheSheet`: Sony now makes `["ps1", "ps2", "psp"]`, not only `["ps1"]`.
- `CatalogTests.everyConsoleNamesItsSystemCoreGlyphAndFiles`: a console with no RetroArch core (Xbox, Switch) lists no core.

Both changes follow from the catalog growing. No test was removed or skipped. `ConsoleScene` (a test helper) gained the scratch `Applications` folder.

## Scenarios

### Detection / Dolphin installed
- Check: test `StandaloneSettingsTests.dolphinIsListedWithItsVersionAndOfferedForGameCubeAndWii` (RetroArchKit), with screenshots `evidence/p16-settings-dolphin-light.png` and `evidence/p16-settings-dolphin-dark.png`. Also `EmulatorDetectionTests` (4 tests).
- Result: pass. A fake `Dolphin.app` (`org.dolphin-emu.dolphin`, version 2509) is in the scratch `Applications`. GameCube and Wii are added. Settings > Consoles shows the following, read back by text recognition:
  - "Other Emulators" lists "Dolphin 2509" with "GameCube, Wii".
  - "GameCube plays in" and "Wii plays in" each show "Dolphin 2509".
  - Each picker offers `["RetroArch (Dolphin)", "Dolphin 2509"]`.
- Detection also checks these cases:
  - Detection works by identifier even when the app is renamed ("PS2 Emulator.app" is found as PCSX2 2.6.3).
  - The version falls back to `CFBundleVersion` when the short version is missing.
  - Detection looks one folder deep, and the first folder wins.
  - Non-emulators and apps with no executable are ignored.
  - Every catalog app is found under the name it ships with.

### Launch with the chosen emulator / GameCube game in Dolphin
- Check: test `StandaloneConsoleTests` "GameCube game in Dolphin: batch mode, Playing in the activity slot, quitting Dolphin clears it" (app). Screenshots: `evidence/p16-activity-dolphin-*.png`, `evidence/p16-panel-dolphin-*.png`, `evidence/p16-activity-after-quit-light.png`. Also `StandaloneLaunchTests.dolphinStartsTheHomebrewInBatchModeAndQuittingEndsIt` (RetroArchKit).
- Result: pass.
  - GameCube is set to Dolphin and Play is pressed. The fake Dolphin's arguments are `["-b", "-e", "<scratch>/My Games/Cartouche Homebrew.dol"]`: batch mode, which runs with no Dolphin user interface and exits when the game stops (Dolphin's `CommandLineParse.cpp` and `MainWindow::OnStopComplete`).
  - RetroArch is never asked (its stand-in has no request).
  - `playing == Playing(gameID, .playing, emulator: "Dolphin")`.
  - The activity slot reads "Playing", "Cartouche Homebrew", "Quit".
  - The panel reads "Playing" and "Plays in Dolphin 2509", without RetroArch's rows ("Lower input lag" absent).
  - The quit file is written, as when the user quits Dolphin. Within 5 s, `playing == nil` and the slot no longer reads "Playing". Play time and last played are recorded.
- Related tests:
  - Quit from Cartouche ends the emulator: polite quit, then SIGTERM.
  - An emulator that exits at once reports "xemu quit at once (exit code 3)."
  - Cartouche quitting leaves the user's emulator running and keeps the play time.
- Not covered here: the real Dolphin. See the maintainer steps.

### Launch with the chosen emulator / Emulator removed
- Check, falling back: test "Emulator removed: GameCube falls back to RetroArch when its core is here" (app).
- Check, not installed: test "Emulator removed and no core: Play shows \"Dolphin is not installed\"" (app), with screenshots `evidence/p16-panel-not-installed-light.png` and `-dark.png`.
- Check, route rules: `StandaloneLaunchTests.aRemovedEmulatorFallsBackOrSaysItIsNotInstalled` and `theShelfFallsBackOnlyWhenTheCoreIsHere`.
- Result: pass.
  - Dolphin was chosen and its app is then deleted. When the Dolphin core is already in Cartouche's cores folder (`dolphin_libretro.dylib`, downloaded when GameCube was added), Play starts RetroArch with that core.
  - With the core also gone, the panel reads "Dolphin is not installed" under a disabled Play, and the Emulator picker shows "Dolphin (not installed)". Play sets the problem "Dolphin is not installed", nothing starts, and `playing` stays nil.
  - Xbox has no RetroArch core and no xemu, so it says "xemu is not installed". Adding Xbox downloads no core.

## Maintainer steps (real apps, real hardware)

1. Install Dolphin in `/Applications`. Open Settings > Consoles and add GameCube: "Other Emulators" shows Dolphin with the version from its About window, and "GameCube plays in" offers it.
2. Add a GameCube homebrew `.dol` or a disc image of your own. Press Play: the game starts with no Dolphin game list, and the sidebar shows Playing. Stop the game or quit Dolphin: Playing goes away within about a second.
3. Move Dolphin to the Trash, then press Play again: RetroArch starts the game with the Dolphin core. Delete `~/Library/Application Support/Cartouche/retroarch/cores/dolphin_libretro.dylib` and press Play: "Dolphin is not installed".
4. For Ryubing, check the bundle identifier with `defaults read /Applications/Ryujinx.app/Contents/Info CFBundleIdentifier`, and check that a game passed as the last argument boots directly. Neither was confirmed from Ryubing's source.
