# Evidence: p12-retroarch-bundle

Branch `phase/p12-retroarch-bundle`, from main a81a5b1. Machine: Apple silicon, macOS 27.0, Xcode 27.0 (Xcode-beta.app), Swift 6.4. RetroArch pinned at `ed3187ec8e1fe55145366789718dc77f34abaeca`.

Three RetroArch builds of the pinned commit were used here:

- **Xcode app**: `make retroarch`'s xcodebuild on `pkg/apple` with `retroarch/xcode/Cartouche.xcconfig`, the build CI ships. Locally Xcode lacks its Metal toolchain (a download, not installed here), so the one Metal shader file fails to compile. Every C, Objective-C and Swift file compiles, the app links and signs ad hoc, and only `default.metallib` is missing, so the Metal video driver cannot run; the OpenGL driver can. Built twice from clean (81 s each).
- **Rig**: `make retroarch-rig`, the same source built with `./configure` and no Metal, which CI uses for the tests.
- **Fake**: `fake-retroarch`, for the tests that need no real build.

Every test that runs a real RetroArch sets `HOME` to its scratch folder and passes Cartouche's own `-c`. After the final runs, `find ~/Documents/RetroArch ~/Library/Application\ Support/RetroArch -newer <marker>` lists nothing.

## Tests

| Suite | Before (baseline given for main a81a5b1; this branch changes nothing in `app/` or `dylib/`) | After (this branch, run here) |
|---|---|---|
| `make -s app-tests` | 554 tests, 34 fail (43 issues) | 554 tests, the same 34 fail (43 issues): "appinfo tool", "Install payload", "Steam installer", all needing the staged payload. `app/` is not changed by this branch. |
| Hermetic C suites from `app.yml` (19), plus `runcheck`, `scriptcheck` | 21 pass | 21 pass (`runcheck` and `scriptcheck` skip: shellcheck is not installed here) |
| `make -s l10ncheck` | pass | pass: 433 strings, all translated for zh-Hans and it except one left in English on main ("The trial version is not supported.", zh-Hans); no app string changed |
| `make retroarch-tests`, no RetroArch | new | 67 tests in 9 suites, all pass; the ones that need a real build are skipped |
| `make retroarch-tests` with the rig and the test core | new | 67 tests, all pass (3 skipped: the real buildbot suite and its test without `CARTOUCHE_NETWORK_TESTS`, and the real-dump BIOS test) |
| `make retroarch-tests` with the Xcode app, `CARTOUCHE_RETROARCH_VIDEO=gl`, `CARTOUCHE_NETWORK_TESTS=1` | new | 67 tests, all pass (1 skipped: the real-dump BIOS test). RetroArch here is the copy embedded in `out/Cartouche.app/Contents/Helpers` |
| `make -s retroarch-l10ncheck` | new | 32 strings, all translated for zh-Hans, it |
| `make -s retroarch-scancheck` | new | pass |
| `openspec validate p12-retroarch-bundle --strict` | valid | valid |

## Scenarios

### Bundled RetroArch built from source / Reproducible build
- Check: CI job `retroarch.yml` (`build` run 1 and run 2, then `reproducible` and `embed`). Locally: command `sh retroarch/scripts/build-retroarch.sh build/retroarch-derived out/retroarch`, a second clean xcodebuild into `build/retroarch-derived-2`, `sh retroarch/scripts/check-retroarch.sh <app> ed3187ec…` on both, and `make retroarch-embed` into a locally built `Cartouche.app`.
- Result: **needs CI** for the full scenario, because the Metal toolchain is missing here. What was shown locally:
  - Both clean Xcode builds succeed except the Metal shader step and print `==> 1.22.2 (Git ed3187e) Oct 19 2026, commit ed3187e, serves --mcp-stdio`. Their executables differ in bytes (build paths and `__DATE__`), which the CI job reports as a notice, not a failure.
  - The check fails as it should on a wrong pin (`--version names ed3187e, the pin is 0123456789abcdef`) and on a build without a commit (`--version names no commit`).
  - `make -o app-payload app`, then `make retroarch-embed RETROARCH_OUT=build/retroarch-derived/Build/Products/Release`, put the Xcode app at `out/Cartouche.app/Contents/Helpers/RetroArch.app`. `check-retroarch.sh` on it prints the same line. `codesign -dv` shows `Identifier=com.libretro.dist.RetroArch`, `Signature=adhoc`, flags `adhoc,runtime`; `disable-library-validation` is kept; `codesign --verify --strict --deep out/Cartouche.app` passes. The whole RetroArchKit suite then passes against that embedded copy.
  - Steps for CI or the maintainer: run the `retroarch` workflow (workflow_dispatch). It installs the Metal toolchain if missing, builds twice from clean (`make retroarch RETROARCH_DERIVED=build/retroarch-derived-N`), and the `reproducible` job runs `check-retroarch.sh` on both artifacts and compares their `--version`. The `embed` job builds `make -o app-payload app`, runs `make retroarch-embed`, then `check-retroarch.sh out/Cartouche.app/Contents/Helpers/RetroArch.app <pin>` and `codesign -dv` on it. Pass when all four jobs are green.

### Bundled RetroArch built from source / Nothing binary in git
- Check: command `make -s retroarch-scancheck` (`retroarch/scripts/scan-binaries.sh` on every tracked file, submodules included, then `retroarch/Tests/scancheck.sh`); CI job `scan`.
- Result: pass. `12746 tracked files, 9 Mach-O, none is RetroArch or a libretro core` (the 9 are upstream's MoltenVK and 3DS/iOS tools in the submodule). The planted fixtures are each caught: a core named `snes9x_libretro.dylib`, the same core renamed `innocent.bin` (found by its `retro_api_version` export), a zipped core, and a `RetroArch.app` bundle; an unrelated Mach-O passes.

### Controlled over MCP / Load and query a game
- Check: test `IntegrationTests.loadAndQueryAGame` on the Xcode app with a window (`CARTOUCHE_RETROARCH_VIDEO=gl`) and on the rig; screenshot `evidence/p12-load-and-query.png` (the frame RetroArch returned for `SCREENSHOT`).
- Result: pass. From a RetroArch not yet running to `GET_STATUS` answering `PLAYING`, content `Test Cart`: 0.35 s on the embedded Xcode app with a window, 0.24 s on the rig without one (limit 5 s). The test cartridge is written by the test (three colour bytes and a title) and the core is `retroarch/Tests/testcore/testcore.c`, built from source. The picture is the cartridge's blue with the moving white bar. `STATE save 1` and `load 1` succeed and write `Test Cart.state1` under Cartouche's states folder.

### Controlled over MCP / Clean stop
- Check: test `IntegrationTests.cleanStop` on the Xcode app and the rig; `SessionTests.aBuildThatIgnoresThePipeIsTerminated` and `aBuildThatIgnoresSIGTERMIsKilled` for the fallbacks.
- Result: pass. Closing the pipe stops RetroArch by its own Quit (`way == .quit`) in 0.025 s on both builds. `kill(pid, 0)` then fails with ESRCH. `Test Cart.state.auto` is written under Cartouche's states folder. With auto save state turned off (`noAutoSaveStateWhenTurnedOff`), no `.state.auto` is written. A build that ignores the closed pipe is terminated, and one that also ignores SIGTERM is killed, both within the time.

### Controlled over MCP / User config untouched
- Check: test `IntegrationTests.userConfigUntouchedAfterTenRuns` (in `UserConfigTests.swift`) on the Xcode app and the rig, and its control `aRewriteWouldBeSeen`.
- Result: pass. The user's `retroarch.cfg` is placed where RetroArch looks for it (`$HOME/Library/Application Support/RetroArch/config/retroarch.cfg`, with `config_save_on_exit = "true"`). SHA-256 before and after ten runs (start, load, save a state, stop): `aa2f7b94…eb33d552` both times on the embedded Xcode app, `c51c1729…a8931110` both times on the rig (each run writes its own user file, so the two differ). The control runs RetroArch once on the user's file with the guard lifted, and the hash changes, so the test can see a rewrite.
- Found on the way: the Xcode app saves its config file after unpacking its bundled assets whatever `config_save_on_exit` says (`menu/menu_driver.c:3999`). That is why Cartouche runs RetroArch on its own `retroarch.cfg` and never on the user's.

### Cores on demand / Add a console
- Check: test `CoreManagerTests.addingSuperNintendoDownloadsOnlySnes9x` (local fixture server); test `BuildbotTests.addingSuperNintendoGetsSnes9xThatLoadsInRetroArch` (real buildbot, `CARTOUCHE_NETWORK_TESTS=1`, Xcode app); screenshot `evidence/p12-add-snes.png`.
- Result: pass. With the fixture server, the cores folder holds exactly `snes9x_libretro.dylib`, and the only core requested is `/nightly/snes9x_libretro.dylib.zip`. Against the real buildbot, the record's source is `https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/snes9x_libretro.dylib.zip`, the cores folder holds only `snes9x_libretro.dylib`, and RetroArch loads it with a homebrew cartridge the test writes (32 KiB LoROM that turns the screen red): `GET_STATUS` reports `PLAYING`, system `super_nes`. The screenshot is the red screen at 256×224.

### Cores on demand / Remove a console
- Check: test `CoreManagerTests.removingSuperNintendoDeletesItsCoreAndNoGame`; also `aSharedCoreStaysWhileAConsoleStillUsesIt`, `deleteRemovesTheFileAndItsRecord`.
- Result: pass. After removing Super Nintendo the cores folder is empty and the console is gone from the list. Three game files (two in a games folder, one inside Cartouche's own folder) keep their SHA-256. A core two consoles share (SameBoy for Game Boy and Game Boy Color) stays until the second is removed.

### BIOS status / PlayStation BIOS
- Check: tests `BIOSTests.readsExtensionsAndFirmwareWithTheirMD5`, `playStationBIOSWithTheRightMD5IsFound`, `removedPlayStationBIOSIsNamedAsMissing`, `aFileWithAnotherMD5IsNotTakenForTheBIOS`, `noDownloadLinkForABIOS`; UI test `ConsolesSettingsTests.thePaneShowsNeedsTheIncludedRetroArch` (text recognition on the drawn pane); screenshots `evidence/p12-settings-consoles-light.png` and `-dark.png`.
- Result: pass for the logic and the UI, with one maintainer step.
  - The SwanStation `.info` gives `scph5501.bin` the MD5 `490f666e1afb15b7362b406ed1cea246`.
  - A repository cannot hold Sony's BIOS, so the "found" test stands in a file of its own and gives the `.info` that file's MD5: status `BIOS found`. A file with another MD5 is `scph5501.bin is not the expected file`. With the file removed: `scph5501.bin is missing`, which the drawn pane shows under PlayStation.
  - No status, no catalog string and no line of code holds a link other than the buildbot and RetroArch's source; the pane's recognised text has no BIOS download.
  - Maintainer step: put your own dump in a file and run `CARTOUCHE_PS1_BIOS=<path to scph5501.bin> make retroarch-tests`; test `aRealDumpIsFound` must pass.

### Version choice / Official release without MCP
- Check: tests `ConsolesSettingsTests.anOfficialReleaseWithoutMCPLaunchesWithLAndSaysWhatItLacks` and `thePaneShowsNeedsTheIncludedRetroArch`; test `IntegrationTests.withoutMCPTheGameStartsFromTheCommandLine` on the Xcode app and the rig; screenshots `evidence/p12-settings-consoles-*.png`.
- Result: pass, with one maintainer step.
  - The official release comes as the buildbot serves it: a disk image at `/stable/1.22.2/apple/osx/universal/RetroArch_Metal.dmg` on a local server, holding a RetroArch.app whose `--help` has no `--mcp-stdio`. Cartouche opens the image read-only, copies the app out, finds no MCP, and launches the game with `-L <core> <file>` and no `--mcp-stdio`. Continue From and Coach mode carry `Needs the included RetroArch`, read back from the drawn pane; with the included build the label is gone.
  - On a real RetroArch started the same way (`mcp = false`), embedded Xcode app and rig: the game starts from `-L`, `GET_STATUS` over the UDP command port answers `PLAYING`, content `Test Cart`, and the UDP `QUIT` stops it with its auto save state written.
  - Maintainer step: in Settings > Consoles pick "Official release 1.22.2" (Cartouche downloads the 233 MB image from the buildbot), add a console, play a game: it starts; the pane lists Continue From and Coach mode as "Needs the included RetroArch".

## Not done here

- Task 1.2 waits for its CI run (Metal toolchain).
- Task 5.1: THIRD-PARTY-LICENSES with RetroArch and the source offer is the docs agent's. `docs/RETROARCH.md` holds the source offer text it can use.
- UI phase checks on macOS 15 and with Reduce Motion are for the maintainer: the pane has no animation of its own; screenshots here are macOS 27, light and dark.
