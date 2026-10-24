# Evidence: p18-onboarding

Branch `phase/p18-onboarding`, from main dc31d75, with main 09f5e80 (P3) merged in before the final checks. Machine: Apple silicon, macOS 27.0 (26A428), Swift 6.4. shellcheck is not installed here, so `make scriptcheck` skips; every new script passes `sh -n` and was checked by hand for quoting.

Nothing here reads or changes the real Steam folder, `~/Library`, `~/Downloads` or the TCC database, and nothing downloads from the internet:

- `install.sh` runs only against fixture releases served on 127.0.0.1 by `packaging/tests/install-test.sh`, installs into a scratch Applications folder, opens nothing (`CARTOUCHE_NO_OPEN=1`), and signs with throwaway certificates in throwaway keychains.
- The disk image is built from a stand-in app and mounted read-only in a temporary folder (`packaging/tests/dmg-test.sh`, `AppLocationTests`).
- The app tests use the Steam fixture of P5 (`SteamFixture`), `FakeTCC` of P17, a scratch home folder, a stand-in controller, and `StubBuildbot`, a URL protocol serving fixture cores inside the test process. No test reaches GameController, `NSWorkspace` or the real `/Applications`.

The package has no XCUITest target, so the "UI tests" of tasks 2.2 to 2.4 drive `OnboardingModel`, which the onboarding view binds to, the way its buttons do, and render each step offscreen into `evidence/` (light and dark; `-macos15` is the classic-materials look forced on this Mac). Run them again with `CARTOUCHE_SNAPSHOTS=<folder> swift test --package-path app --filter Onboarding`.

## Tests

| Suite | Before (main dc31d75) | After |
|---|---|---|
| `make -s app-tests` | 807 tests in 100 suites; the payload set fails (37 test names, 46 issues) | 873 tests in 110 suites (after merging main 09f5e80); exactly the 34 failing test names of P3's `after-failing-tests.txt` (43 issues) |
| `make -s retroarch-tests` | 67 tests, pass | 67 tests, pass |
| `installer` `swift test` | 73 tests, pass | 73 tests, pass |
| Hermetic C suites of `app.yml` (19) | all pass | all 19 pass |
| `make -s packagingcheck` | pass (64 Python tests) | pass, with the new install-test and dmg-test (64 Python tests) |
| `make -s redistscan` | no toolkit file | no toolkit file |
| `make -s -o app-payload app && make -s l10ncheck` | 837 strings, 1 left in English | app built; 930 strings, the same 1 left in English |
| `openspec validate --all --strict` | 19 passed | 19 passed; `openspec validate p18-onboarding --strict` valid |

- The failing app tests need the staged payload or the built helpers ("This build carries no components at all", the appinfo `--platforms` tests). On dc31d75 this machine first showed 37 names: the 34 plus three bridge tests ("A bridge that is already correct is left alone", "A file that is missing or wrong is replaced…", "An empty bridge gets all ten files…") that depend on cached Valve downloads and passed in every later run. Before the merge the branch failed exactly the 34; after it, exactly the 34 P3 lists. No new failure, no test deleted or skipped, no existing test changed.
- A first full run hung: snapshot windows rendered with `windowSnapshot` each leave a thread in a window animation that an invisible window never finishes, and P5's renders plus the onboarding's passed the 64-thread limit of the dispatch pool. The onboarding renders now use `sheetSnapshot` (same capture, `animationBehavior = .none`); P5's helper is unchanged.
- New suites: "Onboarding detection" (`OnboardingDetectionTests.swift`), "Onboarding steps" (`OnboardingFlowTests.swift`), "Onboarding ready and resume" (`OnboardingResumeTests.swift`), "Move to Applications" (`AppLocationTests.swift`); fixtures in `OnboardingFixtures.swift`. New packaging checks, run by `make packagingcheck`: `packaging/tests/install-test.sh`, `packaging/tests/dmg-test.sh`.

## Scenarios

### Install without the Gatekeeper warning / No warning on a clean Mac
- Check: command `sh packaging/tests/install-test.sh` (part of `make -s packagingcheck`). A fixture release (`Cartouche-0.1.0.zip` signed with a throwaway self-signed certificate, `SHA256SUMS` written by `packaging/release.py checksums`) is served on 127.0.0.1; `install.sh`, with that certificate pinned on its `cert_sha1=` line, installs it into a scratch Applications folder.
- Result: pass on the fixture. Output:
  ```
  Downloading the release checksum…
  Downloading Cartouche 0.1.0…
  Checking the SHA-256…
  Checking the signature…
  Installed in /var/folders/…/Applications/Cartouche.app
  ```
  `xattr -p com.apple.quarantine <scratch>/Applications/Cartouche.app` prints `xattr: …/Applications/Cartouche.app: No such xattr: com.apple.quarantine`, and `codesign --verify --strict` passes on the installed copy. Installing again replaces the copy; a copy running from the destination is never replaced ("Cartouche is open. Quit it, then run the command again.").
- If a future macOS quarantines curl downloads, the script says what to expect and prints the three Open Anyway steps (ADR 0012); it never strips the attribute itself.
- Not covered here: a real GitHub release and the absence of the "Not Opened" alert on clean macOS 15 and 26 accounts. That needs a published release and those accounts: manual check M1. Task 1.0 stays unticked for that reason and because shellcheck could not run.

### Install without the Gatekeeper warning / Tampered download
- Check: command `sh packaging/tests/install-test.sh`, case "tampered archive": one byte appended to the served zip, `SHA256SUMS` unchanged.
- Result: pass. Exit status 1, nothing in the scratch Applications folder, the temporary folder (`TMPDIR`) left empty, and the reason printed: `Cartouche was not installed: Cartouche-0.1.0.zip does not match the SHA-256 published with the release, so it was deleted.`
- The same test refuses, with nothing installed: an app signed with another certificate, an ad-hoc signature, another bundle identifier ("the app in Cartouche-0.1.0.zip is not signed with Cartouche's certificate."), a `SHA256SUMS` naming `../good/Cartouche-0.1.0.zip` ("SHA256SUMS names no Cartouche archive."), a missing release, the published script before its certificate is pinned ("this copy of install.sh does not name Cartouche's certificate."), and a plain http URL ("it downloads only over https").

### Installing a non-notarized app / First open from the dmg
- Check: command `sh packaging/tests/dmg-test.sh` (part of `make -s packagingcheck`), which builds a disk image with `packaging/dmg/make-dmg.sh` from a stand-in app, mounts it read-only in a temporary folder and reads its `.DS_Store` back with `packaging/tests/dmg-check.swift`; image `evidence/dmg-window.png` (drawn by `packaging/dmg/preview.swift` from the same background and icon positions).
- Result: pass on the image. It is UDZO (compressed, read-only), named Cartouche, holds `Cartouche.app`, an `Applications` link to `/Applications`, and `.background/background.tiff` with 1x and 2x images. The window record reads `WindowBounds={{200, 120}, {660, 428}}`, no toolbar, sidebar or status bar; icon view at 112 points with `backgroundType=2`; `Cartouche.app` at 170,120 and `Applications` at 490,120, where the arrow on the background starts and ends. Both background references Finder reads resolve to the picture on the mounted copy, though it is mounted somewhere else than where it was built: `. icvp.backgroundImageAlias -> …/mount/.background/background.tiff` and `. pBBk blob bookmark -> …/mount/.background/background.tiff`.
- The window shows the three steps of the mockup (Done; System Settings > Privacy & Security > Open Anyway; password, "Updates won't ask again"). The cask caveats (`packaging/homebrew/cartouche.rb.in`, Ruby syntax checked by `test_release.py`) and the tap README give the same three steps. The release workflow now builds `Cartouche-<version>.dmg` from the signed app and publishes it next to the zip; `SHA256SUMS` keeps only the zip, which is what `install.sh` reads.
- Not covered here: Finder showing the window on a real Mac, the three steps on clean macOS 15 and 26 accounts, and updates opening without a prompt afterwards. Manual check M2. The README has the disk image window; the two macOS screenshots (the "Not Opened" alert and Privacy & Security with Open Anyway) must be taken on those accounts: M2 says which. Task 1.1 stays unticked.

### Detection before questions / Found list
- Check: test `OnboardingDetectionTests.foundList` ("Steam signed in, a DualSense and ~/Games/ROMs: the welcome step lists all three within 3 seconds"); test `OnboardingDetectionTests.deadline`; test `OnboardingDetectionTests.folderRules`; test `OnboardingDetectionTests.welcomeRenders`; screenshot `evidence/onboarding-welcome-light.png`, `-dark.png`, `-macos15-light.png`, `-macos15-dark.png`.
- Result: pass. With the fixture Steam signed in as player42, a DualSense and a scratch `~/Games/ROMs` holding 4 console games, the scan returned in 0.003 s: Steam "Signed in as player42, 8 games", the controller "DualSense Wireless Controller", and `~/Games/ROMs` "4 console games, for Game Boy, Game Boy Advance, and PlayStation". The welcome step shows the found list before any question; its only buttons are Skip Setup and Set Up.
- The list never waits more than 3 seconds (`MacScan.deadline`): a source that takes 5 seconds is left out and the rest shows after 0.3 s in the test with a 0.3 s deadline.
- Only folders with these names in the home folder are looked into: `Games/ROMs`, `ROMs`, `Emulation/roms`, `Emulation`, `RetroArch/roms`, `Games`. Nothing under Documents, Desktop, Downloads, Library, Pictures, Movies or Music is read, even through a symbolic link, and nothing on another disk. Game Porting Toolkit detection leaves `/Volumes` out for the same reason (reading an external disk can show a macOS prompt). The live controller list comes from GameController, which needs no permission.
- Not covered here: a real DualSense and a real Steam account. Manual check M3.

### Short, skippable setup / Skip everything
- Check: test `OnboardingFlowTests.skipSetup` ("Skip Setup on Welcome"); test `OnboardingFlowTests.skipEveryStep` ("Skip on every step"); test `OnboardingFlowTests.choicesInSettings`; screenshots `evidence/settings-general-setup-*.png`, `evidence/settings-library-folders-*.png`, `evidence/settings-compatibility-runner-*.png`.
- Result: pass. Steps are Welcome, PC games, Consoles, Folders and privacy, Ready (5). After Skip Setup, or Set Up then Skip on each step then Open Library, the sheet closes on the library and onboarding is marked done; no runner install, no console added, no write into Steam, no permission request, no game folder saved, privacy unchanged, and Cartouche's RetroArch folder was not even created. It does not show again at the next launch.
- Every choice has a place in Settings: General > Setup > Run Setup Again (the whole onboarding), Library > Game Folders (Add Folder…, Remove), Compatibility > Free Runner (Download), Consoles (P12's pane), Privacy (P17's pane, with Fetch Mac reports from MacGamingDB), and Compatibility > Open Steam Play Setup for Steam.

### Short, skippable setup / Consoles step
- Check: test `OnboardingFlowTests.consolesStep`; test `OnboardingFlowTests.foundConsolesPicked`; screenshot `evidence/onboarding-consoles-light.png`, `-dark.png`, `-macos15-light.png`, `-macos15-dark.png`.
- Result: pass. Picking Super Nintendo and PlayStation makes the button read "Add 2 Consoles". The PlayStation tile and a note below the grid name the BIOS: "scph5501.bin is missing", "Copy it from your own console into the BIOS folder", with Show BIOS Folder (no download link). Add downloads exactly two cores through P12's `ConsoleShelf` and `CoreManager`: the stub buildbot saw `/cores/snes9x_libretro.dylib.zip` and `/cores/swanstation_libretro.dylib.zip` only, though it also served mgba and sameboy; the cores folder holds `snes9x_libretro.dylib` and `swanstation_libretro.dylib`; the shelf lists `snes` and `ps1`.
- Consoles with games in a found folder start picked (Game Boy, Game Boy Advance, PlayStation for the fixture folder) until the user changes the picks.

### Short, skippable setup (App Management only in PC games)
- Check: test `OnboardingFlowTests.appManagementOnlyInPCGames`; test `OnboardingFlowTests.pcGamesStep`; test `OnboardingFlowTests.pcGamesWithoutSteam`; screenshots `evidence/onboarding-pc-games-*.png`, `evidence/onboarding-pc-games-blocked-macos15-*.png`, `evidence/onboarding-pc-games-no-steam-macos15-*.png`.
- Result: pass. Through Welcome, Consoles, Folders and privacy and Ready, nothing is explained or asked and Steam is never written. Only Set Up on the PC games step's "Steam Play in Steam" row (P17's `SteamStep`) shows the App Management explanation; Continue makes the one write into the fixture Steam.app, which is refused, and the row offers Open System Settings and Try Again while Continue stays enabled. `FakeTCC` saw no request at all (macOS has no App Management prompt), and asking for Input Monitoring in the onboarding context is refused. The free runner row downloads the recommended build (Cartouche's own Wine build when the manifest has one, else WineHQ's, today Wine 11.0) and then reads Installed.

### Ends on something playable / Ready with Steam games
- Check: test `OnboardingResumeTests.readyWithSteam`; test `OnboardingResumeTests.readyEmpty`; screenshot `evidence/onboarding-ready-light.png`, `-dark.png`, `-macos15-light.png`, `-macos15-dark.png`.
- Result: pass. With the fixture Steam (player42, 8 games) and the free runner installed from the PC games step, the Ready step reads "Your library has 8 Steam games." and shows Elden Ring, the installed game played last ("Played yesterday"; Counter-Strike 2 was a week ago, Apex Legends is not installed), with its cover and a Play button. Play closes onboarding and plays `steam:1245620` through the library's game actions. With nothing installed the step says "Your library is ready for the games you add." and shows no game.

### Onboarding resumes / Quit midway
- Check: test `OnboardingResumeTests.quitAtEachStep` (one case per step); test `OnboardingResumeTests.quitMidway`; test `OnboardingResumeTests.startOver`; test `OnboardingResumeTests.relaunchRoute`; screenshot `evidence/onboarding-resumed-folders-light.png`, `-dark.png`, `-macos15-light.png`, `-macos15-dark.png`.
- Result: pass. The state (step, picks, folders, consoles already added) is saved in the defaults after every change. A new model on the same saved state, as at the next launch, opens on the same step for each of the five; from PC games on it shows "Welcome back", "You were setting up Folders and privacy. Your choices are kept." and Start Over. In the scenario, Super Nintendo and PlayStation were added, the user reached Folders and privacy and quit: the next launch opens on Folders and privacy with both consoles picked; going back to Consoles offers no download, and Add again sends no request to the buildbot (count unchanged), the two cores still verify. Start Over goes back to Welcome and forgets the picks, but remembers what was downloaded. After P17's relaunch for App Management (route `onboarding` / `pcGames`), onboarding reopens on PC games without the banner.
- Not covered here: quitting the real app. Manual check M4.

### Runs from Applications / Opened from the disk image
- Check: test `AppLocationTests.moveFromDiskImage`; tests `AppLocationTests.classify`, `alert`, `replacesOlderCopy`, `quit`, `nothingAsked`.
- Result: pass on a real disk image. A stand-in `Cartouche.app` on a UDZO image mounted read-only in a scratch folder is classified as the disk image. The alert reads "Move to Applications" with the buttons Move and Quit. Move copies the bundle into the scratch Applications folder (byte-identical executable, nothing half-copied left beside it), asks the relauncher to reopen `<scratch>/Applications/Cartouche.app`, and onboarding does not start from the image. Quit copies nothing and relaunches nothing. A translocated path and `~/Downloads` are offered the move too; `/Applications`, a build folder, `~/Applications` and an app kept on another writable disk are left alone. In the app the check runs first at launch, before onboarding; the live relauncher is P17's (`open -n` on the new path once this copy has quit).
- Not covered here: opening the real app from the mounted release image and seeing it relaunch from `/Applications/Cartouche.app`. Manual check M5.

### Signature explained honestly / Wording check
- Check: command `sh packaging/tests/dmg-test.sh` (wording part), which reads `README.md`, the window's text in `packaging/dmg/background.swift`, the cask template and the tap README; image `evidence/dmg-window.png`.
- Result: pass. Each says Cartouche is "signed with its own certificate", gives Open Anyway and names the install script; none says Apple verified or checked Cartouche (the test fails on "verified by Apple", "Apple verified", "Apple checked"). The window and the README say the certificate does not remove the first-open warning, that it keeps updates and the permissions you grant from resetting, and that the install script avoids the warning.

## Manual checks for the maintainer

Use a fresh macOS user account on macOS 15 and another on macOS 26 (System Settings > Users & Groups), never the daily one. Before M1, set the certificate's SHA-1 on the `cert_sha1=` line of `install.sh` (docs/RELEASE.md, step 5 of "Create it once"), and publish a release or a test release.

- M1. Install script. In Terminal, run the README command. Expected: the four progress lines, "Installed in /Applications/Cartouche.app", Cartouche opens with no "Not Opened" alert. Then `xattr -p com.apple.quarantine /Applications/Cartouche.app` prints "No such xattr". Save the Terminal output in this file. Then download `Cartouche-<version>.zip` from the release with Safari, change one byte (`printf x >> Cartouche-<version>.zip`), serve its folder with `python3 -m http.server --bind 127.0.0.1 8000` next to the release's `SHA256SUMS`, and run `CARTOUCHE_RELEASE_URL=http://127.0.0.1:8000 sh install.sh`: it must stop with the SHA-256 message and install nothing.
- M2. Disk image. Download `Cartouche-<version>.dmg` with Safari and open it. Expected: the window opens at about 660 by 400 with the arrow, the two icons on the arrow's ends, the three steps and the signature note; check icon labels are readable in light and dark mode. Drag to Applications, open Cartouche: take `docs/images/install/not-opened-15.png` (or `-26`) of the alert, click Done, take `docs/images/install/open-anyway-15.png` of Privacy & Security, click Open Anyway, confirm. Cartouche opens. Add both screenshots to the README's Disk image section. Install the next release through Sparkle: no Gatekeeper prompt. Repeat with `brew install --cask bryann2k/cartouche/cartouche`: the caveats print the three steps.
- M3. Detection. With Steam signed in, a DualSense connected and `~/Games/ROMs` holding a few games, open Cartouche for the first time (fresh account, or `defaults delete dev.bryann2k.cartouche onboarding.state`). Expected within 3 seconds: Steam with the account name and game count, the controller, the folder with its consoles. No macOS prompt appears at this point.
- M4. Resume. Pick two consoles, Add, reach Folders and privacy, quit with ⌘Q. Reopen: Folders and privacy with "Welcome back", the two consoles still picked, no download in Console.app's log for those cores.
- M5. Move to Applications. Open Cartouche straight from the mounted disk image (and once from `~/Downloads` after unzipping there). Expected: "Move to Applications" with Move and Quit; Move relaunches Cartouche from `/Applications/Cartouche.app` within a few seconds, then onboarding starts.
- M6. Onboarding end to end (P17's M4): complete it with every option on. The only macOS notice is App Management's block notification; Cartouche is never asked to quit.

## What is left, and why

- Tasks 1.0 and 1.1 are not ticked: they need clean macOS 15 and 26 accounts and a published release (M1, M2), and shellcheck could not run here.
- Task 3.1 is not ticked: APPFLOW is the docs agent's.
- The onboarding does not offer "Suggest installers in Downloads", "Measure FPS" or "Share results with MacGamingDB", which the mockup shows. None of these features exists yet (P6 did not build the Downloads watcher, P8 is not built), and P17's spec forbids asking for a permission no feature needs. Folders and privacy offers the game folders and the existing "Fetch Mac reports from MacGamingDB" choice.
- Game folders are saved (`library.gameFolders`) and listed in Settings > Library; watching them for new games is P13's.
