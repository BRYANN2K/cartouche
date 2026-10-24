# Evidence: p8-performance-tracking

Branch `phase/p8-performance-tracking`, cut from main 09f5e80 (P3 archived). Machine: Apple silicon, macOS 27.0, Xcode 27.0. Rosetta is present, so the x86_64 slice ran too. Nothing was pushed, nothing was installed, no workflow ran on GitHub. Tests use fixtures, scratch folders and scratch UserDefaults; none reads or writes the user's Steam or `~/Library`. No CrossOver, Wine build or Game Porting Toolkit is on this Mac, so every check on a real runner or a real game is marked **needs maintainer** with exact steps.

## Tests

| Suite | Before (main 09f5e80) | After (branch head) |
|---|---|---|
| `make -s app-tests` | 846 tests in 106 suites, 34 fail (43 issues) | 869 tests in 111 suites, the same 34 fail (43 issues) |
| Failing test names | `evidence/baseline-failing-tests.txt` (34, the payload ones) | `evidence/after-failing-tests.txt`, `diff` empty |
| Hermetic suites from `app.yml`, plus `runcheck`, `scriptcheck` | all pass | all pass, plus the new `fpscheck` and `fps-counter-tests` (`evidence/after-suites.txt`) |
| `make -s compatcheck` | runs `backendcheck` | runs `backendcheck`, then `fpscheck` |
| `make -s retroarch-tests` | 67 tests in 9 suites pass | the same |
| installer `swift test` | 73 tests in 11 suites pass | the same |
| `make -s packagingcheck` | pass | pass |
| `make -s redistscan` | pass | pass, also on `out/Cartouche.app` |
| `make -s -o app-payload app && make -s l10ncheck` | 856 strings | 870 strings, all translated for zh-Hans and it (the same one zh-Hans string left in English, from before) |
| `openspec validate --all --strict` | pass | 19 passed; `openspec validate p8-performance-tracking --strict` valid |

- After merging main da94105 (P18, P13) into the branch: `make -s app-tests` 923 tests in 124 suites, the same 34 fail (`diff` against `evidence/baseline-failing-tests.txt` empty); every hermetic suite above passes; `retroarch-tests` 99 tests in 14 suites, installer 73 tests in 11 suites, `packagingcheck` pass; `redist-scan.sh` on `git archive HEAD` finds no Game Porting Toolkit file; `l10ncheck` 1012 strings, all translated (the same one zh-Hans string in English); `openspec validate --all --strict` 19 passed. The catalog was merged by key: main's "Played" (from P13) is kept with its translations.
- New Swift suites (23 tests, `evidence/swift-p8-suites.txt`): "Frame counter deployment" (3), "Performance store" (7), "Play time averages" (4), "Your Play" (5), "Sharing frame rates" (4).
- New shell and C checks: `fps-counter/tests/counter.sh` (`make fps-counter-tests`, added to `app.yml`), `fps-counter/tests/bench.sh` (`make fps-counter-bench`, manual, 15 minutes), `dylib/tests/fpscheck.sh` (`make fpscheck`, also run by `make compatcheck`).
- Existing tests edited: `IdentityTests` scans the new `fps-counter/` folder in its two folder lists (stricter, not looser). No test was skipped or deleted.
- `runcheck` and `scriptcheck` skip: shellcheck is not installed here. `sh -n dylib/feats/compat_run.sh` passes; `lint.yml` runs shellcheck in CI.

## How it fits together

- **Counter.** `fps-counter/fps_counter.m`, built as `out/fps-counter.dylib` with x86_64 and arm64 slices (ad hoc signed). With `CARTOUCHE_FPS_DIR` set, it replaces `-[CAMetalLayer nextDrawable]` and counts each drawable returned. D3DMetal, DXMT and DXVK through MoltenVK all take their drawables there; Valve's overlay hooks the same method. The first frame starts one thread that writes `samples-<pid>` once a second: `<unix time> <frames> <frontmost> <width> <height>`. Frontmost is `[NSApp isActive]`; a process with no NSApp counts as frontmost. A process that presents nothing writes nothing.
- **Injection.** The run script (`prepare_fps`, after `install_bundle`, before `open`) makes `performance/incoming/<appid>-<time>-<pid>/session` with the app, runner build, translation, backend, tool name, start time and the game's `D3DM_ DXMT_ DXVK_ MTL_ ROSETTA_` variables. dyld kills a process whose inserted library fails to load, so it first runs the bundle's Wine loader with `--version` and the counter inserted; the counter writes a probe marker. No marker or a failed run means `measure=refused`, and the game starts without the counter. The result is kept per runner in `performance/probe-<build>-<arch>` until the loader or the counter changes. The launcher adds the counter after the overlay shim and Steam's overlay. `ended=` is written when the game exits. `CARTOUCHE_FPS=0` in the launch options turns it off.
- **Store.** `PerformanceStore` reads each finished folder into `performance/sessions.sqlite` (tables `sessions` and `samples`), then deletes the folder. A folder without `ended=` that has not changed for 15 minutes is read as ended at its last sample. A second counts after the first 30 seconds from the first frame, when frontmost, and with at least 5 frames (fewer is a loading screen or a stall). The game's process is the samples file with the most frames.
- **Numbers.** Session average = counted frames / counted seconds. 1% low = mean of the slowest 1% of counted seconds (at least one). A game's and a setup's average are weighted by measured time; play time is the sum of session durations, launch to exit. A setup is runner build, translation and backend.
- **UI.** Your Play comes after Play once the game has a session: Average, 1% low, Played; "Best with <backend>" and "Compare N Setups" when there are two setups or more; "FPS can't be measured with this runner" when the latest session's runner refused the counter. Compare Setups lists every setup with average, 1% low and play time, tags the best and offers Use This Setup (sets runner, translation, backend, and the Windows version for a game with a Mac build). Sessions are read in when a panel opens and when Cartouche becomes active.
- **Sharing.** Settings > Privacy > "Share my frame rates with MacGamingDB", off by default. A report is `{mac: {chip, ram_gb, macos}, runner, runner_build, translation, backend, settings, fps: {average, low_1_percent, measured_seconds}}`; the game is in the address, not the body. `settings` keeps only Cartouche's variable names, drops `*_PATH` and `*LOG*`, keeps values of letters, digits and `.,-_+:` up to 32 characters, and adds `resolution`. MacGamingDB publishes no way to send reports, so this build has no address: the toggle is disabled with "Cartouche can't send reports to MacGamingDB yet, so your frame rates stay on this Mac."

## Measurement / Accuracy

- Check: `make -s fps-counter-tests` → `evidence/fps-counter-tests.txt`. The Metal test app (`fps-counter/tests/present.m`) presents a 1280x720 scene locked at 60 fps for 6 s with the counter inserted, on each slice.
- Result: pass. arm64: every whole second 60 ± 1, average 60.0, 360 of 360 frames counted, size `1280 720`. x86_64 under Rosetta: every whole second 60 ± 1, average 60.0.
- Check: `make -s fps-counter-bench` → `evidence/fps-counter-bench.txt` (300 s locked at 60, first 30 s left out as the app does).
- Result: pass. arm64: average 60.00 fps over 267 counted seconds (min 59, max 61). x86_64: 60.00 fps over 268 s (min 59, max 61).
- **Needs maintainer** for the spec's per-backend run (tasks 1.3 and 1.2 left unticked):
  1. `make app`, open `out/Cartouche.app`, Steam Play Setup > Install (this deploys `fps-counter.dylib` to `~/Library/Application Support/Cartouche/`). Restart Steam.
  2. Pick a game with an in-game frame limiter, set it to 60 fps, V-Sync off, in a static spot (a menu scene with 3D, or standing still in game). For each of CrossOver 26.3 · D3DMetal, · DXMT, · DXVK set in Cartouche: launch from Steam, stay in front for 5 minutes, quit.
  3. Open the game in Cartouche. Compare Setups shows each backend's average. Expected 59.0 to 61.0 for each. Record the three values, and `sqlite3 "$HOME/Library/Application Support/Cartouche/performance/sessions.sqlite" 'select backend, measured_seconds, average from sessions'` in `evidence/backends-accuracy.txt`.

## Measurement / Background time is ignored

- Check: test `PerformanceStoreTests.background` ("Background time is ignored: 2 minutes away in a 10-minute session leave 8 minutes, minus the first 30 seconds"): a launch folder with 600 one-second samples, not frontmost from second 200 to 319.
- Result: pass. Measured time 450 s (8 min − 30 s), within ± 5 s; 600 samples stored, 450 counted, no background second counted; play time 610 s.
- Check: `make -s fps-counter-tests`, "an app that is not active is marked as background": the test app with an NSApplication that is never activated writes `frontmost=0` on every line, on both slices.
- Check: test `PerformanceStoreTests.warmUpAndLoading`: the first 30 s and 30 s at 2 fps (a loading screen) leave 180 of 240 s.
- **Needs maintainer** for a real game: launch any game, play 4 minutes, switch to Finder for 2 minutes, come back 4 minutes, quit. `sqlite3 …/sessions.sqlite 'select measured_seconds, ended - started from sessions order by id desc limit 1'` should give about 450 and about 600.

## Measurement / Low overhead

- Check: `make -s fps-counter-bench` → `evidence/fps-counter-bench.txt`. The test app's CPU-bound bench (each frame rendered, plus 8 ms of CPU work, so the rate sits below the display's pacing), 5 runs of 10 s with and 5 without the counter, in alternating order, after a warm-up run.
- Result: pass. arm64: 113.70 fps without, 113.70 with, +0.00%. x86_64: 112.68 without, 112.70 with, +0.02%. Both under 1%.
- **Needs maintainer** for a game benchmark: a game with a built-in benchmark (for example Shadow of the Tomb Raider), run it 3 times with `CARTOUCHE_FPS=0 %command%` in Steam's launch options and 3 times without; the benchmark's own averages should differ by less than 1%.

## Your play / Weighted average

- Check: tests `PlayStatsTests.weighted` and `weightedStored` (14.2 h at 56 fps and 1.1 h at 34 fps, directly and through the SQLite store), and `YourPlayTests.weightedInPanel`.
- Result: pass. The weighted average is 54.4, shown as "54 fps"; the plain mean would be 45. The panel's sections are Play, Your Play, Expected on This Mac; Played reads "15 hr, 18 min".
- Screenshots: `evidence/panel-your-play-light.png`, `-dark.png`.

## Your play / Compare setups

- Check: test `YourPlayTests.compare` ("Compare Setups lists each setup with average, 1% low and play time, marks the best, and offers to use it"), three setups, the game set to DXVK.
- Result: pass. Rows, best first: `CrossOver 26.3 | DXMT, Rosetta | 56 fps | 41 fps | 14 hr, 12 min`, `CrossOver 2026 08 21 FEX | DXVK, FEX | 40 fps | 31 fps | 30 min`, `CrossOver 26.3 | D3DMetal, Rosetta | 34 fps | 22 fps | 1 hr, 6 min`. The best is DXMT, tagged Best, with Use This Setup; after it, the game's resolved backend is DXMT and the row would read In Use. The panel reads "Best with DXMT" and "Compare 3 Setups".
- Check: test `PlayStatsTests.perSetup`: sessions of one setup add up (2 h at 50 + 6 h at 70 = 65 fps, 8 h, 1% low 47.5 from the merged seconds).
- Screenshots: `evidence/compare-setups-light.png`, `-dark.png`, `evidence/panel-your-play-three-setups-light.png`, `-dark.png`.

## Privacy / Off by default

- Check: test `PerformanceSharingTests.offByDefault`. A URLProtocol registered for the whole process records every request `URLSession.shared` starts, with its body. With default settings (and even with a test address to send to), a session is read in while running and after it ended.
- Result: pass. `PrivacyChoices.sharePerformance` is false by default; no recorded request goes to the report address or carries `fps` or `measured_seconds`.
- Check: test `PerformanceSharingTests.unavailable`: this build has no MacGamingDB address (`PerformanceSharing().isAvailable == false`), so even with sharing on nothing is sent and no request can be built.
- Check: code. The counter and the run script open no network connection; the only sender is `PerformanceSharing.share`, called from `PerformanceModel.refresh` with the setting.
- **Needs maintainer** for a capture on a real session: with default settings, run `sudo tcpdump -i any -w ~/Desktop/p8.pcap` (or Little Snitch) during a 5-minute session and 2 minutes after; no connection from Cartouche, the game or the run script other than those in `docs/PRIVACY.md`.

## Privacy / What is shared

- Check: test `PerformanceSharingTests.whatIsShared`, sharing on, a test address, a session whose settings carry `DXVK_LOG_PATH=/Users/player42/logs` and a value with a Steam ID.
- Result: pass. One POST to `https://reports.cartouche.test/games/1245620/reports`. Body keys exactly `mac, runner, runner_build, translation, backend, settings, fps`; `mac` = `{chip: "M4 Pro", ram_gb: 24, macos: "26.1.0"}`, runner `CrossOver 26.3`, backend `dxmt`, settings `{MTL_HUD_ENABLED: 1, D3DM_ENABLE_METALFX: 1, resolution: 2560x1440}`, fps `{average: 58, low_1_percent: 58, measured_seconds: 300}`. The body contains no `player42`, no `/`, no `/Users`, no home folder, no user name, no Steam ID. A second refresh sends nothing again.
- Check: test `PerformanceSharingTests.onlyMeasured`: a refused session makes no report; sharing off sends none.
- Not decided: where reports go. See "Left open" below.

## Injection is safe / Blocked injection

- Check: `make -s fpscheck` → `evidence/fpscheck.txt`. The run script's blocks run against scratch trees with the Metal test app as Wine's loader: one that takes the library, a hardened-runtime copy that ignores it, and one dyld kills when the library cannot load (an x86_64-only counter in an arm64 loader: exit 134 when inserted anyway).
- Result: pass. Accepting loader: `measure=on`, the counter inserted, the game's process writes samples at 60 fps, `ended=` written. Hardened and killed loaders: `measure=refused`, nothing inserted, the game runs normally (60 frames in 1 s), no samples, the run log says `fps: refused by <loader>`. The probe result is reused and tried again when the loader changes. The launcher order is overlay shim, Steam's overlay, then the counter.
- Check: `make -s fps-counter-tests`, "a hardened binary still runs … and refuses the library: no marker, no samples", both slices.
- Check: test `YourPlayTests.blocked`: a refused session shows Your Play with Played "2 hr" and "FPS can't be measured with this runner".
- Screenshots: `evidence/panel-your-play-refused-light.png`, `-dark.png`.
- **Needs maintainer** on each real runner (task 1.2 left unticked):
  1. After the install in step 1 of Accuracy, launch one game with each runner set up (CrossOver 26.3 Rosetta, a CrossOver FEX build on macOS 26, a Wine build, Game Porting Toolkit if present).
  2. `grep '^fps:' <steamapps>/compatdata/<appid>/cartouche-run.log` names `ok` or `refused` for each runner; `cat "$HOME/Library/Application Support/Cartouche/performance/probe-"*`.
  3. For an `ok` runner, the game's panel shows Your Play with an average after 30 s of play. For a `refused` one, the game still started and the panel shows "FPS can't be measured with this runner". Save the outputs in `evidence/runners.txt`.

## Left open

- Task 1.2: integration on each real runner, steps above.
- Task 1.3: accuracy and overhead per backend in a real game, steps above. The synthetic runs per slice are done.
- Task 4.1: PRIVACY and DATA-SCHEMA are the docs agent's.
- Sharing has no destination: MacGamingDB publishes no API to send reports, and the spec names none. The payload, the setting and the tests are in place; `PerformanceSharing.macGamingDB` is nil, so the toggle is disabled.
- The spec lists what the body carries; the game's Steam App ID is not in that list, so it is in the address, as in MacGamingDB's read API.
- wined3d draws through OpenGL, not CAMetalLayer, so its sessions record play time but no FPS ("No FPS measured yet"). The spec asks for D3DMetal, DXMT and DXVK.
- Your Play shows for Steam games (by Steam App ID). Games added through Windows installers run as Steam shortcuts; their sessions are stored under the shortcut's ID but no panel reads them yet.
