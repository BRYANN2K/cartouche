# Evidence: p6-windows-installer

Branch `phase/p6-windows-installer`. Checked on an Apple M4, macOS 27.0, Xcode 27 toolchain (Swift 6.4), 2026-10-19.

How the checks were run:

- InstallerKit: `swift test` in `installer/` (also `make -s installer-tests`, now a CI step).
- App: `make -s app-tests`; the installer suites alone with `swift test --filter "Install"` in `app/`.
- Screenshots: `CARTOUCHE_SNAPSHOTS=<folder> swift test --filter "InstallSheetTests/snapshots"` in `app/`, which renders the real `InstallSheet` view offscreen in light and dark. They are in `evidence/` (`installer-<step>-<light|dark>.png`). macOS 27 only; covers show the game name because the offscreen render does not load network images.
- Every test uses temporary folders and an injected support folder. No test reads `~/Downloads`, the real Steam folder or the user's Trash. The "installer" in the flow tests is a shell script standing in for Wine; the dropped folder's `setup.exe` is a trap script that leaves a marker if anything on the host runs it.

Not covered here, for the maintainer (real hardware or a real installer):

- A real multi-part Inno installer run end to end (task 5.1). Steps at the end of this file.
- The eslogger capture (task 1.4): eslogger needs root, which this session does not have. `sudo sh installer/scripts/no-exec-check.sh <folder>` records it.

### Analysis without execution / Multi-part Inno installer
- Check: test `InstallSheetTests` "A two-part Inno installer: Inno Setup 5.5, 2 parts, heavy decompression, checksums OK, game identified" (innoextract's recorded `--info`/`--list` answers for a 5.5.0.1 installer, two parts, `MD5/checksums.md5` with Windows paths); test `InstallerKitTests.readsInnoextractOutput`; screenshot `evidence/installer-2-analysis-light.png`, `-dark.png`.
- Check (time): command `installer/.build/release/installer-inspect "<folder>" --verify` on a synthetic folder with `setup.exe`, `data-01.bin` and `data-02.bin` (2 × 5.96 GB sparse files, 11.1 GB as the app counts it) and `MD5/checksums.md5`:
  ```
  Parts:       2, 11.1 GB
  Verified:    ["data-01.bin": "ok", "data-02.bin": "ok"] in 9 s
  real 8.98
  ```
- Result: pass on synthetic data. Rows shown: "Inno Setup 5.5 installer", "With heavy decompression (unarc, isdone, cls-srep)", "2 parts found", "Files are intact / Checksums match", "Identified as …", "Enough space". Checks finish in 9 s for 11.1 GB, under the 30 s limit. Sparse files read faster than an SSD, so the maintainer's real run is the final proof (the 2026-10-18 manual run in `mockup/INSTALLER.md` took 18 to 19 s).

### Analysis without execution / Missing part
- Check: tests `AnalysisTests` "A required part that is missing is red, named, and blocks Install" and `InstallSheetTests` "A missing required part is named in red, Continue is disabled and Check Again is offered".
- Result: pass. The row reads "data-02.bin is missing" with the `.failed` (red) state, `canContinue == false`, `hasBlockingProblem == true` (the view shows Check Again), and Check Again after the file is restored re-enables Continue.

### Analysis without execution / Optional parts
- Check: tests `AnalysisTests` "When the manifest says parts may be optional, a missing one is orange and Install stays enabled", "A manifest entry outside the numbering that is absent is also listed", and `InstallSheetTests` "A missing part the manifest calls optional is orange and Install stays possible".
- Result: pass. The row reads "data-02.bin is missing", detail "It may be optional: …", state `.warning` (orange), and Continue stays enabled.

### Analysis without execution / No execution
- Check: tests `NoExecutionTests` (3 tests): a folder whose `setup.exe`, parts, `unarc.dll` and manifest are all executable trap scripts is analysed with a recording innoextract and with the real innoextract 1.9 (installed here); a source guard keeps `Process(`, `posix_spawn`, `NSWorkspace`, `execv` and `system(` out of the analysis files.
- Result: pass. No trap fired; the only process started was innoextract, called as `--info <folder>/setup.exe` (and `--list` when the installer is Inno).
- Pending: eslogger capture by the maintainer with `sudo sh installer/scripts/no-exec-check.sh <folder>`; here `eslogger exec` answers "Not privileged to create an ES client, need to be superuser".

### Installation with real progress / Install completes
- Check: tests `InstallFlowTests` "A sheet left open moves to the exe step without a notification" and "A background install …"; `InstallLaunchTests` (5 tests); `InstallPrefixTests` "The install uses the runner's x86_64 Wine, so it runs under Rosetta"; `InstallRunnerTests` "A fake installer that writes files and exits 0 …".
- Result: pass with a scripted Wine. The calls recorded by the Wine script are `x86_64 wineboot --init` then `x86_64 <folder>/setup.exe /DIR=C:\Games\Sample Game /NORESTART /LOG=C:\installer.log /LANG=en`: `uname -m` reports x86_64, so the run went through `arch -x86_64` (Rosetta); the prefix is new (`installs/sample-game/pfx`); `/DIR` prefills the folder in Guided mode. Progress rises with the folder size (fractions sorted ascending, last above 0.5) and the sheet's step becomes `chooseExe` ("Which file starts the game?") after exit code 0. Screenshot `evidence/installer-4-installing-*.png`, `evidence/installer-5-exe-*.png`.
- Not done: the integration test with a sample Inno installer built in CI (task 2.1). Building one needs Inno Setup's compiler, which runs on Windows only. The real-installer run by the maintainer covers it.

### Installation with real progress / Background install
- Check: test `InstallFlowTests` "A background install: the sheet closes, the activity shows progress, the notification says it is installed".
- Result: pass. After `continueInBackground()` the sheet is closed (`isSheetPresented == false`), the install continues, `InstallCenter.activity` reports rising fractions while it runs and is nil after, and the notifier receives "Sample Game is installed". `UserInstallNotifier` posts it with an Open action that reopens the sheet on that job; it posts only when notifications are already allowed (NotificationOffer asks first when a PermissionFlow is set). The real banner was not seen in a running app: the library window is the only host and the app was not launched in this session.

### Installation with real progress / Stuck installer
- Check: tests `ProgressTrackerTests` "No growth for 5 minutes with the CPU under 2% is stuck" (not stuck at 299 s, stuck at 300 s, cleared by growth) and "No growth while the CPU is busy is not stuck"; `InstallRunnerTests` "A fake installer that stops writing and idles is reported stuck, and Stop ends it" and "CPU is sampled over the installer's processes, children included" (one busy child shell reads between 30% and 150%); `InstallFlowTests` "A stuck installer is reported, and Stop ends it and removes the unfinished attempt" (stuck threshold shortened to 1 s); screenshot `evidence/installer-4b-stuck-light.png`, `-dark.png`.
- Result: pass. The sheet shows "The installer seems stuck." with Show Installer Window and Stop; Stop ends every process of the installer and removes the unfinished game folder.

### Failure and retry / Decompression error
- Check: tests `InstallLogTests` (8 tests on synthetic logs in Inno 5.5's format: unarc -11, ISDone "not found any file specified for ISArcExtract", full disk, clean log, cancel codes 2 and 5, fatal exception, corrupted setup, UTF-16 log); `RetryFixTests` (8 tests); `InstallFlowTests` "A decompression error offers the retries, and a retry runs again with the changed inputs"; screenshot `evidence/installer-4c-failed-light.png`, `-dark.png`.
- Result: pass. Causes in order: "Not enough memory for the decompressors", "A path the installer cannot handle", "A damaged installer file". Buttons: Verify Files, Retry with Fewer Threads, Retry with Less Memory (and Retry with a Short Path). Retry with Less Memory runs the installer again in a fresh prefix with `memoryPercent == 50`, which the CLS.ini override writes into the decompressors' settings. Each fix changes the next run's inputs (`RetryFixTests` "Every fix changes the next run's inputs").
- The logs are written for the tests, not recorded from a real failure.

### Playable result / Executable ranking
- Check: tests `ExeScanTests` "The Start Menu shortcut's target comes first, the launcher second, the uninstaller is not listed" (a fixture prefix with `game.exe`, `SampleLauncher.exe`, `unins000.exe`, `_Redist/dxwebsetup.exe`, Start Menu `.lnk` files in Wine's format and an Uninstall key in `system.reg`) plus 6 more in that suite; screenshot `evidence/installer-5-exe-*.png`.
- Result: pass. Order `game.exe` ("From the Start Menu shortcut", preselected and marked Recommended), then `SampleLauncher.exe` ("Launcher from the publisher"); `unins000.exe` and `dxwebsetup.exe` are not listed.

### Playable result / Redistributables
- Check: tests `RedistributablesTests` (3 tests, 16 cases) and `InstallFlowTests` "A background install …" (the install folder holds `_Redist/dxwebsetup.exe`).
- Result: pass. The scripted Wine was called exactly twice (wineboot and setup.exe), so `dxwebsetup.exe` was not run; winetricks received `["d3dx9"]`; the exe step says "DirectX 9 and Visual C++ 2015–2022 installed" (screenshot). Visual C++ maps by year to `vcrun2005` … `vcrun2022`.
- Limit: an installer's own [Run] entries execute inside Wine during the install when the installer itself chooses to run them; Cartouche does not run them and cannot block them.

### Playable result / Cleanup is never automatic
- Check: test `InstallFlowTests` "Finishing writes the record, the launcher and the Steam shortcut; the installer files stay until Delete is confirmed"; screenshot `evidence/installer-6-ready-*.png`.
- Result: pass. After the install and after Continue, every installer file still exists; Delete… only asks (`cleanup == .confirming`, nothing trashed); after Move to Trash, `setup.exe`, `data-01.bin`, `data-02.bin` and `checksums.md5` go to the Trash function (a recording stand-in in the test, `FileManager.trashItem` in the app) and the row says "Installer files moved to the Trash. … freed." Files are trashed one by one, and the folder only when it is empty and not one of the user's own folders.

### Identify the game and its cover / Matched by installer title
- Check: tests `GameIndexTests` "The installer title is matched before the folder name" (title "CarX Street" against an index with CarX Street, App ID 1465360) and "Ten installer folder names find their Steam App ID" (10 cases); `InstallSheetTests` "A two-part Inno installer …" (installer title "Disco Elysium" against the compatibility data fixture: match 632470, the row carries the cover); `InstallerMatchTests` (the compatibility records are the name index; cover URL `…/apps/632470/library_600x900.jpg`).
- Result: pass. The review step shows the Steam portrait art from that URL (not visible in the offscreen screenshots, which do not load network images).
- Not done: MacGamingDB is not searched by name. The app reads MacGamingDB only by App ID (ADR 0013, PRIVACY.md), so name matching uses the compatibility data only. See the report.

### Identify the game and its cover / GOG installer
- Check: tests `GameIndexTests` "A GOG info file is used first, and its name finds the Steam entry" and "A GOG ID in the installer's file list is kept even without a match"; `ExeScanTests` "A GOG info file's play task is preferred over the size".
- Result: pass. With `goggame-1207658924.info` present the source is `gog`, `gogID == "1207658924"`, and its name finds The Witcher 3 (292030), whose Steam cover is used. The GOG ID is also read from the installer's file list before installing. A cover from GOG itself is not fetched (no GOG request is made); an unmatched GOG game falls back to the name cover.

### Identify the game and its cover / User corrects the match
- Check: test `InstallSheetTests` "Picking another game in the review step switches the cover and the match"; `GameIndexTests` "The user's correction replaces the match", "Search finds games by word prefixes, exact name first".
- Result: pass. Searching "elden" and picking Elden Ring switches `appID` to 1245620 (the cover URL follows it), the name and install folder to "Elden Ring", and the source to `user`. The compatibility data and recommended setup for the game come from P3/P4 by App ID; the record keeps the chosen App ID.

## Test runs

- InstallerKit: before 9 tests; after 73 tests in 11 suites, all passing.
- App (`make -s app-tests`): before 696 tests, 34 failing (the known payload failures); after the merge of main, 807 tests, the same 34 failing and no other (the installer suites add 22 tests: InstallFlowTests 5, InstallSheetTests 6, InstallLibraryTests 4, InstallPrefixTests 5, InstallerMatchTests 2, plus RunnerRegistryTests unchanged and green).

## Steps for the maintainer: one real multi-part Inno installer

1. `make innoextract` (or have Homebrew's innoextract), then build and open Cartouche.
2. Library > Add Games… > Windows. Drop the folder with `setup.exe`, its `.bin` parts and `MD5/`.
3. Note the analysis rows and the time to "Files are intact" (should be under 30 s for ~11 GB).
4. Install in Guided mode with a ready runner. Check the installer window shows `C:\Games\<Name>`, the progress rises, and Continue in Background closes the sheet while the notification "<Game> is installed" arrives at the end.
5. Check the exe step's first choice and the redistributables line, then Continue with Show in Steam on (Steam closed).
6. Check `~/Library/Application Support/Cartouche/installs/<slug>/install.log` and `wine-output.log`.
7. Optional: `sudo sh installer/scripts/no-exec-check.sh <folder>` and paste its output here.
