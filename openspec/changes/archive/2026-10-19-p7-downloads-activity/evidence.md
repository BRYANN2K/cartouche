# Evidence: p7-downloads-activity

Branch `phase/p7-downloads-activity`, from main dc31d75, with main merged in before the final checks: 09f5e80 (P3), da94105 (P18, P13) and e802c33 (P8). Machine: Apple M4, macOS 27.0, Xcode 27 beta toolchain (Swift 6.4), 2026-10-19.

No test reads or writes the real Steam folder, `~/Library` or the notification center. Steam's files come from `DownloadFixture` (`app/Tests/NotProtonAppTests/ActivityTests.swift`), a scratch folder with `appmanifest_*.acf` files carrying byte counts, `logs/content_log.txt`, `logs/gameprocess_log.txt` and `registry.vdf`. The library window scenes reuse P5's `SteamFixture`. Game processes in tests are `/bin/sleep` and `/bin/sh` children of the test. No `steam://` link is opened: tests pass a recording opener. Facts about Steam's files and its client API are in `docs/research/p7-steam-downloads.md`, with what is and is not confirmed.

How to run the checks again:

- Unit and flow tests: `swift test --filter "Activity|SteamDownload|GameProcess|Notification|Reveal"` in `app/`.
- Screenshots: `CARTOUCHE_SNAPSHOTS=<folder> swift test --filter "ActivitySnapshotTests|RevealTests|RevealStillTests"` in `app/`.
- Performance: `CARTOUCHE_BENCH=1 swift test --filter RevealBenchTests` in `app/` (needs a display; skipped otherwise).
- Page code: `make -s panel-behavior` (`dylib/tests/panel-behavior/downloads.js`) and `make -s webpatch-fixtures` (command file paths in `gatecheck`).

## About the screenshots

As in P5, every PNG in `evidence/` is rendered offscreen (`NSView.cacheDisplay`, or `ImageRenderer`), in light and dark. Liquid Glass, materials, vibrancy and some accent fills are not drawn by this capture: the sidebar's background comes out blank, text inside glass groups can come out dark on dark, and the green live dot comes out white. Offscreen captures cannot hold a Metal layer, so these screenshots show covers with the still split (`\.revealStill`); the Metal effect itself is captured frame by frame through `RevealRenderer.render`, and recorded as `evidence/reveal.mov`.

The library is rendered as its parts (sidebar with the slot and grid in one window, God of War's panel in a window of the inspector's width), not as the whole `NavigationSplitView`, and only with the macOS 26 look. Each window with AppKit controls rendered offscreen leaves an AppKit animation thread stuck in the test process; P5's window tests already leave about 45, and at 64 `DispatchQueue.global()` stops running work, which hung `PrefixesModelTests` ("A superseded tool scan cannot replace the newer prefix records") in a full run. With fewer windows the full run passes. The slot and panel bars are drawn shapes rather than `NSProgressIndicator` for the same reason.

## Scenarios

### One activity slot / Priority
- Check: test `ActivityCenterTests.playingWhileDownloading` ("Priority: a running game shows with its FPS and Quit, and the download stays in the status menu"); test `ActivitySlotTests.priority` (all 16 combinations of running game, install, downloads, updates, and the status menu sections for each); test `GameProcessTests.quit`; screenshots `evidence/sidebar-activity-playing-light.png`, `-dark.png`, `evidence/slot-playing-*.png`, `evidence/slot-playing-retroarch-*.png`.
- Result: pass. With Elden Ring tracked as running and God of War at 16.08 of 47.3 GB, the slot is `.playing(Elden Ring)` with 58 fps and a Quit button; the status menu has a Playing section ("Elden Ring 58 fps", Quit Game) and a Downloads section ("God of War 34%"). Quit sends SIGTERM to the processes Steam tracks for the game (`gameprocess_log.txt`), their children, and anything running from the game's install folder, then SIGKILL after 5 s; an unrelated process is left running.
- Limit: the FPS number needs a live value from P8. P8 (merged) records FPS per session for Your Play but exposes no value while the game runs, so `ActivityCenter.fps` is not wired yet. The slot shows the fps when that source gives it, and only the live dot and Quit otherwise. The test injects 58.
- Limit: Steam's running game is read from `gameprocess_log.txt` (format from a secondary source), then `RunningAppID` in `registry.vdf` (reported to stay 0 with the new UI), not checked against a real game. Manual check M2.

### One activity slot / Nothing to show
- Check: test `ActivityCenterTests.nothingToShow`; test `ActivitySlotTests.nothing`; screenshot `evidence/sidebar-activity-hidden-light.png`, `-dark.png`.
- Result: pass. With only installed games and `RunningAppID` 0, `slot == nil` and the status menu has no activity section; the sidebar has no card.

### Download progress / Pause from Cartouche
- Check: test `ActivityCenterTests.pause` ("Pause from Cartouche: the command goes to Steam and the ring shows the paused symbol at once"); test `SteamDownloadCommandTests.commandFile`; page test `dylib/tests/panel-behavior/downloads.js` (10 checks, `make -s panel-behavior`); path test in `gatecheck` (8 paths, `make -s webpatch-fixtures`); test `SteamDownloadStateTests.manifests` and `.contentLog`; screenshots `evidence/slot-paused-*.png`, `evidence/panel-download-block-paused-*.png`, `evidence/panel-downloading-light.png`, `-dark.png`.
- Result: partial. Cartouche's side passes: Pause writes `{"id":1,"appid":1593500,"verb":"pause","at":…}` to `steam-downloads.json` at once and the ring switches to the two-bar paused mark in the same call; it stays paused until Steam's manifest (bit 512) or content log agrees. The injected page polls the file every 1000 ms and calls `SteamClient.Downloads.PauseAppUpdate(1593500)` once, so Steam gets the command within about 1 s of the click, inside the 3 s limit. The page ignores commands older than 30 s, verbs other than pause and resume, and app IDs that are not whole positive numbers.
- Not proven: that Steam's loopback host reads `steamui/cartouche/steam-downloads.json` through the hooked `open` (it may check the folder first), and that `PauseAppUpdate` pauses rather than removes the download (one source says it may behave like `RemoveFromDownloadList`). Both need a real Steam with the rebuilt dylib: manual check M1, task 1.2.

### Cover reveal / Progress drives the reveal
- Check: test `RevealTests.halfway`, `.rises`, `.moves`; screenshots `evidence/reveal-frame-10.png`, `-34`, `-50`, `-90`, `-finish`; video `evidence/reveal.mov` (6 s, 5% to 100% then the finish ring); comparison `evidence/reveal-webgl-vs-metal-50.jpg` (built by `evidence/reveal-compare.py`); test `RevealBenchTests` (with `CARTOUCHE_BENCH=1`); screenshot `evidence/library-downloading-light.png`, `-dark.png` (God of War's cover in color up to 34%, "Downloading, 34%" under it, the ring in the slot).
- Result, coverage: pass. At 50% the Metal frame has 55.5% of its pixels in color: the bottom quarter 100%, the top quarter 0.003% (the embers). At 0, 25, 50, 75 and 100%: 0.003%, 23.2%, 55.5%, 77.3%, 99.7%.
- Result, faithful port: pass. The mockup's GLSL, taken verbatim from `launcher.html`, run by WebGL in a browser on the same cover and uniforms (P 0.5, t 1.3), against the Metal frame: mean difference 0.43 of 255 per channel, no pixel off by more than 24.
- Result, performance on an M4: one revealing cover drawn by an MTKView at 60 Hz for 5 s: 59.9 fps, process CPU 1.95% to 2.30% (idle window 0.01%); three covers: 60.0 fps each, 2.6% to 3.9%. GPU time for one 360×540 frame: 1.6 to 3.2 ms (the Mac was shared with other builds). The spec's limit is 5% on an M1.
- Not done: the M1 measurement with Instruments (task 2.2). The test process gets no display link, so the bench drives `MTKView.draw()` from a 60 Hz main-queue timer, the same call the display link makes; the M1 run in the real app is manual check M3.

### Cover reveal / Reduce Motion
- Check: test `RevealStillTests.reduceMotion`; screenshot `evidence/reveal-reduce-motion-50.png`.
- Result: pass. `CoverReveal.usesShader(reduceMotion: true)` is false, so no Metal view is made. At 50% every row above the middle is gray (under 1% colored pixels) and every row below is in color (over 99%): a straight edge. Two renders are byte for byte the same, so nothing moves; no embers. At 25% exactly 25% of the cover is in color.

### Notifications / Ready to play
- Check: test `ActivityCenterTests.finishes`, `.foreground`, `.cancelled`, `.fails`, `.offersNotifications`; test `ActivityNotificationTests.readyToPlay`, `.downloadFailed`, `.installs`, `.oneDelegate`; test `InstallFailureNotificationTests.failure`.
- Result: pass on the model and the delegate. A download whose manifest goes from 1026 to 4 while Cartouche is in the background posts one notification titled "God of War is ready to play" with the action "Play"; answering that action opens `steam://rungameid/1593500`. In the foreground nothing is posted; a cancelled download (manifest removed) posts nothing; a failure posts "God of War could not be downloaded" with Steam's reason and Try Again. A failed install in the background posts "Sample Game could not be installed" with Open. The first finished download opens P17's explanation ("Get a notification when a game is ready?") before any macOS prompt, and only once.
- Not done: a banner from the real notification center. `UNUserNotificationCenter` needs the bundled app, and tests never post to it. Manual check M4.

## Test runs

| Suite | Before (main dc31d75) | After |
|---|---|---|
| `make -s app-tests` | 807 tests (main dc31d75), the 34 known payload failures | 963 tests after the merge of main e802c33, exactly the 34 known payload failures and no other (`diff` of the failing names against the dc31d75 run, which also had 3 more payload-dependent Steam install tests failing) |
| `make -s retroarch-tests` | – | 67 tests pass |
| InstallerKit `swift test` | 73 tests pass | 73 tests pass |
| Hermetic suites of `app.yml` (20), and `packaging/redist-scan.sh` on `git archive HEAD` | – | all exit 0 |
| `make -s -o app-payload app && make -s l10ncheck` | strings of main, 1 left in English | app built and signed ad hoc; 1048 strings after the merge of main e802c33, the same 1 left in English |
| `openspec validate --all --strict` | – | 19 passed, 0 failed; `openspec validate p7-downloads-activity --strict` valid |

New suites in `app/Tests/NotProtonAppTests/`: "Activity slot", "Activity center", "Steam download state", "Steam download commands", "Game processes" (`ActivityTests.swift`), "Notifications", "Install failure notification" (`ActivityNotificationTests.swift`), "Cover reveal", "Cover reveal with Reduce Motion" (`RevealTests.swift`), "Cover reveal performance" (`RevealBenchTests.swift`, opt-in), "Activity screens" (`ActivitySnapshotTests.swift`). No test was removed, skipped or changed.

## Choices made without the maintainer (to review)

- **Pause and Resume through the injected page.** Steam has no `steam://` link for either. The app writes a command file; the page code the dylib already injects reads it from Steam's own loopback host and calls `SteamClient.Downloads`. The page only reads; nothing the page does can write a file. Rejected: Steam's CEF remote debugging port (opens a debugger to any local process), and a WebUI route (needs a protobuf message type the client already has for this).
- **Cancel and Try Again are `steam://uninstall/<id>` and `steam://install/<id>`.** Steam asks before deleting. Rejected: `RemoveFromDownloadList`, whose effect on a first download is not confirmed.
- **The ring pauses and resumes; it does not cancel.** The mockup's ring button cancels the download in one click; a 47 GB download lost to a misclick seemed worse than one more click in the panel. Cancel is in the panel.
- **Runtime-compiled Metal, not a SwiftUI `[[stitchable]]` shader.** The offline `metal` tool is an optional Xcode component, missing here ("missing Metal Toolchain") and not guaranteed on CI. `MTLDevice.makeLibrary(source:)` needs nothing extra. An MTKView per revealing cover, as the mockup has one canvas per cover; it stops drawing when its window is covered.
- **Selected covers show full color while downloading**, as in the mockup; the reveal is on the other covers and in the install sheet.
- **Install reveal**: the install sheet's cover now uses the same reveal (it was a uniform saturation) when the game is identified.
- **Running game**: Steam's `gameprocess_log.txt` first; macOS no longer shows other processes' environment (`SteamGameId`), checked on this Mac with `ps -E`.
- **Updates in the slot**: the slot and menu show `ActivityCenter.updates`, which no phase fills yet (runner and backend updates belong to P2 and P3).
- **Console sessions (P13)**: `ActivityCenter.follow(_:)` reads `ConsoleCenter.playing`, so the slot reads "Playing on RetroArch" ("Starting…" with Quit disabled while RetroArch starts) and Quit goes to `ConsoleCenter.quit()`. P13's own sidebar card gave way to the slot; its file became `Consoles/CRTPowerOn.swift`, and its test `ActivityQuitTests` renders the sidebar with the slot through `follow(_:)` and still finds "Playing", the game's name and "Quit".
- `PermissionCenter.refresh(_:)` was added to read only the notifications state at launch, and `InstallNotifying.failed` with a default, so P6's mocks still compile.

## Manual checks for the maintainer

- M1. Pause on a real Steam (task 1.2): rebuild and deploy the dylib (`make deploy`), restart Steam, start downloading a free game under 1 GB, click Pause in Cartouche's panel and time how long Steam's Downloads page takes to show it paused (limit 3 s); then Resume and Cancel. If it does not pause, look in Steam's web helper console for "Cartouche: pause the download of app …"; no line means the loopback host did not serve the file.
- M2. Launch that game from Steam: the sidebar shows "Playing <Game>" with Quit; Quit ends it within 5 s. Check `~/Library/Application Support/Steam/logs/gameprocess_log.txt` holds "AppID … adding PID …" lines.
- M3. On an M1, with Instruments (Time Profiler and Metal System Trace), keep one game downloading with its cover visible for 30 s: record the frame rate and Cartouche's CPU (limit 5%).
- M4. Let a download or an install finish with Cartouche in the background: the explanation sheet first, then after Continue the macOS prompt; the next one shows "<Game> is ready to play" with Play, which starts the game.
- M5. Reduce Motion on: the downloading cover is a still split.
- M6. Run `out/Cartouche.app` on macOS 15 and 26: the slot, the panel block, light and dark.
