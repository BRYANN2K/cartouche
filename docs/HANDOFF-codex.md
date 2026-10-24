# Handoff to Codex — 0.1.0

Integration branch: `claude/sleepy-cerf-8bbse7` (BRYANN2K/Cartouch-work). Mac qualification started on 2026-10-22 from **`8502d45f0b6e7709dc15fd2e198785b516739275`**. The cloud session had no Swift toolchain; the local results below supersede that limitation for this exact snapshot and the listed local fixes.

Validation checkout: `/Users/user/Documents/Projects/Cartouche-0.1.0-validation`, branch `fix/0.1.0-mac-validation`. Changes remain local and uncommitted. No app release, deployment, signing-key change or integration-branch push was performed.

## Maintainer setup: Cartouche Wine updates

The app learns about new Cartouche Wine builds from a signed runner manifest. The `cartouche-wine` repository's CI publishes it on the `manifest` release:

- `https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json`
- `https://github.com/BRYANN2K/cartouche-wine/releases/download/manifest/runners.json.sig`

The app accepts the manifest only when the signature verifies against `SUPublicEDKey` in `app/Info.plist`. A missing or bad signature keeps the bundled `runners.json` in use.

**To do once, by hand:**

1. In BRYANN2K/cartouche-wine, go to Settings → Environments and create the environment `release` if it does not exist yet.
2. In that environment, add the secret `SPARKLE_PRIVATE_KEY`.
3. Its value is **the same EdDSA key as the app's Sparkle updates**: the content of the exported key file, which is one base64 line. Use the same value as the `SPARKLE_PRIVATE_KEY` secret in Cartouch-work. Never commit it.
4. Optionally, protect the `release` environment with required reviewers. The workflow that signs the manifest then waits for approval.

Without this secret, the signing step fails with `SPARKLE_PRIVATE_KEY must be set` and no manifest is published. Wine releases are still built, but the app never offers them as updates.

If the key is lost or changed, installed copies reject every new manifest and every app update. See `docs/RELEASE.md` § Sparkle key.

## Branch state at qualification

- `Cartouch-work/main`: `d2a016f6d149e502aa80369805f71cc922e8334d`.
- Integration: `8502d45`, 115 commits ahead of that main, with no main-only commits. It includes the public runner-manifest URL, games-location changes, problem banners and game-exit notices (WP1/WP2), and per-game Wine tools and Steam running-state/Stop changes (WP5/WP8).
- These changes have not been merged into `Cartouch-work/main` by this qualification. The isolated checkout preserves the other local worktrees.
- `cartouche-wine` is a separate repository. Its only branch is now `main`; the two existing release tags were retained. Use `main` for its manually dispatched workflows.

## Local toolchain and checks

Host: Apple silicon, macOS 27.0 (`26A428`), Xcode 27.0 (`27A5252f`), Swift 6.4, macOS SDK 27.0. Compilation targets macOS 15.0; this does not prove runtime behavior on macOS 15 or 26.

Logs are kept in `.scratch/qualification-0.1.0/` in the validation checkout, including the initial failures. This folder is ignored by Git.

| Check | Result |
| --- | --- |
| `swift test --package-path installer --no-parallel -j 2` | Passed: 211 tests in 25 suites. |
| `swift test --package-path retroarch --no-parallel -j 2` | Passed: 165 tests in 27 suites, with opt-in network and real-RetroArch cases skipped by their existing conditions. |
| `swift test --package-path app --no-parallel -j 4` | Failed: 71 issues recorded before an assertion stopped the test process (signal 5). See the failure inventory below. |
| `swift build --package-path app -c release --product NotProtonApp -j 4` | Passed: optimized app executable compiled. A complete local app bundle was subsequently assembled and launched; see the local trial below. |
| Filtered continuation after the Steam upkeep assertion | Completed: 246 tests in 32 suites, 7 issues; the corrected upkeep test passes. The exact filter is in `.scratch/qualification-0.1.0/remaining-filter.txt`. |
| `make appinfo` | Passed: native appinfo helper compiled. |
| `make iconmaker settingscheck` | Passed after the local MainActor fix. |
| `python3 dylib/tests/shortcut-launch.py out/iconmaker` | Passed with a synthetic home, shortcuts, image input and invalid/unwritable output cases. |
| PNG → ICNS smoke check | Passed; the output has an ICNS header and the temporary iconset is removed. |
| App feed URL / workflow public key | Match between `app/Info.plist` and `cartouche-wine/.github/workflows/runner-manifest.yml`. |

### Local compilation fixes

1. `GameWineToolsTests.swift`: replace a key-path predicate inside `#expect` with an explicit closure. Swift Testing's macro expansion inferred a throwing predicate and did not compile.
2. `StagedGamesTests.swift`: import `InstallerKit`, which defines `WineRunner`.
3. `helpers/iconmaker.swift`: call the MainActor-isolated image writer with `MainActor.assumeIsolated` from the synchronous CLI entry point, which runs on the main thread. The successful ICNS conversion and existing failure-path tests exercise this call.

4. `SteamUpkeepTests.swift`: move the test's process probes into `offMain`, preserving the app's prohibition on synchronous process waits on the MainActor. The original full run stopped on that assertion; a continuation run covers this suite and the later test suites.

### App test failures and coverage limits

The initial full execution recorded 71 issues across fixture/payload, UI and functional assertions before the test-process assertion. This is **not** a green full suite. `.scratch/qualification-0.1.0/app-failure-inventory.md` lists every recorded source location and assertion; `app-tests.log` retains full diagnostics.

- Several `AppInfoToolTests` and `SteamInstallerTests` need the complete staged payload and bridge files. At the time of that test run, this isolated checkout was not prepared with `make app-payload`; compiling `out/appinfo` alone does not embed those files in SwiftPM resources. Prepare the complete payload and rerun those tests before attributing their failures to product regressions.
- OCR/UI assertions failed in Agents settings, console panels/sidebar, controller settings, drop detection, game verification and other views. The current host is macOS 27; these still require diagnosis and supported-system validation, rather than removing or skipping assertions.
- Other failures include canonical path expectations, permission gating, identity checks, localization fallback and keyboard setup. Their relation to the integration changes versus the baseline has not been established by a separate baseline run.
- The initial execution did not reach the remaining suites after the Steam upkeep assertion. The filtered continuation completed with 246 tests in 32 suites and 7 issues. It confirms the corrected upkeep test passes without the MainActor assertion. All seven continuation issues are UI text assertions in `StoreUITests.swift` (store descriptions and sign-in/sign-out rows); their exact locations are in the same failure inventory. This does not turn the aborted run into a passing full run.

## Runner-manifest publication state

Read-only GitHub checks on 2026-10-22 found **no environments** in `cartouche-wine`; the `release` environment is not created. The `manifest` release is also absent (HTTP 404). Repository-secret listings were also empty in both `cartouche-wine` and `Cartouch-work`; `Cartouch-work` has no environments either. In particular, the referenced Sparkle secret is not currently present in those repository/environment listings. The maintainer must use the existing exported key or its secure backup; GitHub cannot return a secret value for copying. No private-key value was read or copied.

- The app bundles manifest revision **2**, pinning Cartouche Wine `26.3.0-1`.
- The public repository contains manifest revision **3**, pinning `26.3.0-1` and `26.3.0-2`.
- `26.3.0-2` is already a published prerelease. Earlier roadmap/audit statements that it is unpublished are stale.
- The app's public key matches the workflow's `APP_PUBLIC_KEY`. That checks the public configuration, not the existence or correctness of the private secret.
- Until the maintainer creates `release`, adds the existing key and promotes a Mac-tested build, the remote signed feed cannot be published. The app continues to use its bundled manifest.

The setup steps above remain manual. After a real prefix-boot and controller check, dispatch `runner-manifest` on `cartouche-wine/main` with the tested build ID and `confirm_tested=true`; then verify both public assets and their signature. Do not rotate the existing Sparkle key to solve a missing secret.

## Still unverified before 0.1.0

- Distribution signing, DMG installation, update delivery and Homebrew installation. The local ad-hoc-signed bundle is assembled and launches; this does not qualify distribution or every game.
- Supported-system UI checks on macOS 15 and 26, light/dark mode, Reduce Motion, onboarding and permissions. The current host is macOS 27.
- Real Steam repair/export and account switching; Wine first boot and a controller with `26.3.0-2`; real-game Stop behavior without stopping store clients.
- Silksong / D3DMetal, CarX Street, installer cancellation and direct-unpack fallback; user-supplied archive coverage.
- Real store sign-ins, cloud saves on two Macs, physical controllers, real RetroArch cores, netplay and RetroAchievements. Fixture tests do not qualify these integrations.
- FPS accuracy and overhead on real runners/backends, complete RetroArch embedding in the release pipeline, and the remaining feature/audit questions listed in `docs/ROADMAP.md` and `.claude/reports/features-doc-vs-built-2026-10-22.md`. The feature audit describes a prior source snapshot and must not be read as live validation of this checkout.

Maintainer tasks beyond the Wine feed remain the runner/billing configuration, app signing certificate and release secrets, preservation of the existing Sparkle key, and the Homebrew tap. See `docs/RELEASE.md`. They were not configured by this local qualification.

## Complete local trial build

After the initial SwiftPM qualification, the maintainer requested a functional app to try. `out/Cartouche.app` is now assembled, ad-hoc signed and launched from this validation checkout.

- Rebuilt Cartouche's native dylib, overlay/FPS libraries, native helpers and both Unix lsteamclient halves from this branch. Reused local dependency/build caches, fonts and unchanged bridge PE outputs; reused the pinned innoextract and libarchive binaries. Their hashes and origins are in `.scratch/qualification-0.1.0/reused-build-inputs.json`.
- Installed Xcode's missing Metal Toolchain and built the pinned RetroArch `ed3187ec8e1fe55145366789718dc77f34abaeca`, checked its MCP option, then embedded it in Cartouche.
- Fixed bundle assembly to restore the exact staged payload after SwiftPM resource processing. The bundle check now compares file contents rather than only checking for nonempty files. The final `make app` and `make retroarch-embed` both passed.
- All 35 staged payload files match the embedded copies by SHA-256. Archive helpers and RetroArch are present; `codesign --verify --strict --deep` passes. The receipt is `.scratch/qualification-0.1.0/complete-bundle.json`.
- The actual Cartouche library window is visible. Its Steam status says integration updates when Steam quits; Steam has not been force-quit for this trial. Close and reopen Steam to load the new integration.
- The prior test failures remain historical evidence; the full test suite has not been rerun against this complete payload. No real-game/controller/store validation or release acceptance is claimed.

## Follow-up trial checks, 2026-10-22

The later local changes supersede the earlier limitations where explicit evidence follows:

- Steam import lists 156 owned games. Integration upgrades are manual (local integration version 0.1.0-3).
- A real Steam installation of 3D Aim Trainer (1600530) was initiated from Cartouche’s runner/graphics/location sheet. The WebUI install-manager API acknowledged the request, Cartouche displayed download progress, and Steam’s manifest reached StateFlags 4, SizeOnDisk 823667019, BytesDownloaded 495169984. No steam://install URL is used by this Install action. Steam’s client services still run in the background.
- Distinct request protobuf vtables fix a native dispatch collision between the install and library-export routes. services-check now rejects duplicate request vtables. Native services/export checks, panel behavior and backendcheck passed; see unique-install-routes.log and unique-routes-panel-backend-tests.log.
- The bundled ProtonDB aggregate covers 1,491 games with multiplayer answers from the official reports_oct1_2026 export. tools/compat/build_protondb.py regenerates it under ODbL. Counts retain their source/date and link to the game page; they do not establish macOS anti-cheat support. The former blanket VAC rejection has been removed: CS2 remains unverified, matching the Mac catalog’s Unknown status.
- The latest targeted check passed 34 tests in five suites (vac-status-steam-completion-tests.log); the compatibility pipeline passed 47 tests (protondb-pipeline-tests.log). These are targeted checks, not a passing full app suite.
- A download manifest lacking the fully-installed flag vetoes an installed claim from the running Steam export, so Setup stays hidden until installation completes.
- Library sections now reserve a common 22-point heading row before the grid, including source-only views.
- A second Cartouche process was observed running from NotProton/.claude/worktrees/cloud-build/out/Cartouche.app. Local verification targets the validation checkout explicitly; that other process was not terminated.

The prior successful CarX renderer trial used an isolated engine clone and the user confirmed DualSense menu navigation. Production renderer-cache integration passed targeted tests; this note does not claim a fresh normal-app gameplay trial. Signing-key configuration, remote signed feeds, real GOG sign-in and supported-system qualification remain outstanding as described above.

Steam uninstall follow-up: a completed/handed-off install request is cleared when Steam activity takes ownership, preventing a later uninstall from resurrecting the old queued UI. Cartouche-initiated Steam uninstall records the existing manifests/prefixes before opening Steam’s confirmation. Two successive absent-manifest checks on connected libraries precede prefix cleanup. Cancelling the uninstall, disconnecting a library, an active prefix or an escaping symlink never triggers deletion. Prefix backups retain PrefixTools’ existing preservation behavior. The game is then reloaded and marked uninstalled while the next Steam export catches up. The request watcher lasts up to two minutes while Cartouche remains running.

The uninstall regression checks passed 11 tests in two suites, including the actual GameActionRunner menu path with simulated Steam confirmation and dedicated-prefix cleanup (`steam-removal-final-tests.log`). The broader preceding run passed 36 tests in five suites (`steam-removal-tests.log`). Neither test uses real game data.

Final local bundle: `final-card-wording-build.log` and `final-card-retroarch.log` passed; deep strict signature verification passed. The validation app was relaunched after rebuilding. Visual checks confirm the first card row remains aligned between All Games and Steam (`grid-gap-all-games.png`, `grid-gap-steam.png`). The old Linux-specific card warning was replaced by “Anti-cheat unsupported”. The removed 3D Aim Trainer shows Install again and no Setup or pending installation block. Luna’s source comparison is recorded in `docs/research/anti-cheat-sources-2026-10-22.md`; no Highball integration has been claimed or added.

Steam runner/Stop and mixed-grid follow-up: installed-game Setup now appears directly after Play, with runner/backend changes disabled while the game runs. Native Steam games also expose Stop. Game tracking resolves Windows executable arguments through the selected prefix's actual dosdevices links; this identifies reparented Wine children whose macOS executable lives under winetemp rather than the Steam install folder. The fix was motivated by live 3D Aim Trainer processes using S:\\steamapps\\common\\3D Aim Trainer\\3dat.exe. Stop retains game-specific process/prefix targeting. The targeted regression run passed 41 tests in six suites (steam-stop-runner-grid-final-tests.log); an older trailing-slash path assertion was corrected to compare normalized directory prefixes.

Mixed library sections use one cover frame shape: portrait if any PC game is present, square for console-only sections. Console art remains fully fitted inside the shared frame, so favorite-card titles align without cropping or stretching the artwork. The existing library/console-cover tests passed (16 tests, mixed-cover-tests.log).

The runner/Stop/mixed-grid release build and RetroArch embedding passed (`steam-stop-mixed-grid-build.log`, `steam-stop-mixed-grid-retroarch.log`), followed by deep strict signature verification and an app relaunch. The Favorites screenshot `favorites-mixed-aligned.png` confirms shared cover heights with full console artwork. During final inspection 3D Aim Trainer had already been uninstalled and its former processes had exited; no new real-game Stop click is claimed. Community-site work remains a V1 proposal in cartouche-site/docs/community-compatibility-v1.md, with the source-precedence choice pending and no report backend or nightly mirror activated.


Installer FPS and panel alignment follow-up: installer games now start their own performance session, migrate existing launchers to probe the frame counter, and inject it only when their Wine loader accepts it. Session completion feeds the same local performance store as Steam. The game panel looks up installer statistics using the compatibility app ID, rather than requiring a Steam library entry. Verification is a compact title badge with its explanation in a tooltip; active file verification retains its progress and Stop control.

The targeted Swift run passed 58 tests in nine suites (`local-fps-tests-qualified.log`), including both successful/refused probe paths, synthetic-frame ingestion, session cleanup and panel rendering. Native counter checks passed on ARM64 and x86_64 (`local-fps-native-final.log`). Initial native checks exposed timing-sensitive assertions demanding exactly 60 frames in short non-measuring smoke tests; those assertions now require a successful exit and positive presentation count. Measured-rate checks retain their 60 ± 1 FPS requirement. A direct probe of CarX’s actual graphics runner accepted the x86_64 counter (`carx-fps-loader-probe/marker`). These checks alone do not establish measured CarX gameplay performance.

The FPS release bundle and RetroArch embedding passed (`local-fps-build.log`, `local-fps-retroarch.log`), with deep strict signature verification. The app was relaunched and CarX started from its normal Play button. Session `1114150-1792694265-5F479AE6-6E1D-434C-AF9F-5A3F974077BA` records `measure=on`; `samples-54456` contains actual frames, window activity and 1710×1112 drawable sizes. These are loading-screen samples, not a gameplay benchmark. CarX was left running. `carx-compact-verification.png` confirms the title badge and shared title/action spacing.

After CarX exited, the session was ingested without intervention: 270 counted seconds, 11,430 frames, average 42.33 FPS, 1% low 10 FPS, duration 377 seconds. The actual app shows “Your Play” with 42 FPS, 10 FPS and 6 min (`carx-measured-session.png`). This includes the trial/loading period and is not a controlled gameplay benchmark. No force-quit was issued for this session.


Automatic Switch artwork: Switch games now resolve icons and banners through Nlib using a title ID in the filename. Raw file tags are removed from the displayed name while the original game ID, saves and favorites remain unchanged. Console menus no longer offer Steam cover search; local-image overrides remain available. Existing libretro artwork behavior is retained for other consoles. `switch-artwork-tests-final.log` passed 24 tests in five suites. The release build and RetroArch embedding passed (`switch-artwork-build.log`, `switch-artwork-retroarch.log`), followed by deep strict signature verification and relaunch. The actual Hades entry downloaded its icon (866,706 bytes) and banner (315,591 bytes) automatically and displays both with the cleaned title (`hades-automatic-artwork.png`). These images are cached for offline use. Files without a recognizable Switch title ID still need a local cover; no ROM decryption or title-ID guessing is performed.


## Console runtime installation on import, 2026-10-23

ConsoleCenter.addGames now prepares each console runtime before storing game entries, including consoles already added. It reuses detected apps, reinstalls missing RetroArch cores, or installs a pinned official standalone archive into ~/Applications. Explicit emulator choices are respected. Missing-runtime game panels expose Install rather than a disabled Play button. The import sheet remains open with progress, failure/retry and cancellation; folder imports use the same preparation method. Eden v0.2.1 is the default missing Switch runtime, while existing Ryubing installations are reused. No user settings, keys or firmware are supplied or replaced.

Targeted app checks passed 16 tests in four suites (`emulator-complete-tests.log`), covering pending preparation before publication, missing runtime on an existing console, hash mismatch, retry, cancellation, reuse, explicit standalone choice and existing import/launch flows. RetroArchKit catalog/detection checks passed nine tests (`emulator-catalog-final-tests.log`), including the empty CFBundleExecutable in Eden's actual release. The broader watched-folder run retained one unrelated Settings form accessibility assertion failure: “Watched. 4 games found” was absent before the new game-import path was reached (`emulator-watch-recheck.log`); the other two watched-folder tests passed, including an actual directory-watch import after about 1.05 seconds. No full-suite green result is claimed. Official sources and pins are recorded in docs/research/standalone-emulators.md and Resources/emulators.json.


2026-10-23 follow-up: console installation and shared game files

- Official Eden 0.2.1 is installed at `~/Applications/eden.app`, detected by the running validation app, and passes deep strict signature verification. The cached DMG hash matches the bundled pin. Hades remains one library entry, with “Plays in Eden”. This verifies runtime installation/detection, not Hades gameplay or firmware setup.
- Switch containers skip full-file CRC/database lookup when no matching database exists; the 4 GB sparse-container regression and catalog/detection checks passed 25 tests in three suites. Drop classification now runs off the UI executor. The existing unavailable-backend DropSheet AX rendering assertion still fails before classification begins; the watched-folder AX assertion documented above also remains. No full-suite green claim.
- Integration revision 0.1.0-4 guards only Cartouche-owned install-manager events, preserving Steam's UI for other installations. Closed Steam starts with `-silent`. The app requires the manual Settings update before using an older worker. The installed live integration remains 0.1.0-3; it was not replaced or Steam restarted during this work, per the manual-update requirement. Live OS focus behavior therefore still needs a trial after that update.
- Steam's previous-runner refusal was removed. Game content and same-architecture prefixes are reused; locks and architecture checks remain. GOG/Epic/Amazon resolve the selected runner against their existing content/prefix; Windows installer games retain their existing launcher-rewrite path.
- `shared-install-app-tests.log`: 25 tests in five suites passed, including three store cases that launch, switch to another runner, switch back, preserve a save and the executable's file identifier, and make no additional install/download calls. Also covers installer setup, emulator import/install and manual integration-version gating.
- `shared-install-steam-tests.log`: 20 game setup and Steam setup checks passed. `shared-install-native-final.log`: build changes and webpatch fixtures passed. The actual installed Steam sp.js has exactly one callback anchor matching the guard fixture. The compiled guard behavior test preserves other app events and completion events, suppressing only the owned wizard. The unscoped live gatecheck additionally reports the existing platform-filter fixture limitation when no platform-list provider is supplied; it is not an OS focus test.

The user confirmed console imports work. The shared-install release build and RetroArch embedding passed; deep strict signature verification passed and the app was relaunched. A subsequent visual-only change centers the Steam integration alert as a compact row, vertically aligns its icon/text/action, and uses the existing pill button style. `centered-banner-build.log` and `centered-banner-retroarch.log` passed; the running release was visually checked after relaunch. Steam integration remains a manual update.

2026-10-23 visual follow-up: Liquid Glass, updates and Settings title

- Artwork saturation/opacity and panel shadows were reduced. Navigation/search use untinted regular glass; the game inspector uses standard material. Round actions and the primary action use native interactive glass, retaining accessibility and older-system fallbacks. System secondary labels replace fixed translucent text colors. Recent systems no longer stack the manual scroll fade over native edge effects. See `docs/research/liquid-glass-macos27.md` for scope and Apple references.
- General Settings now includes the app version and Check for Updates button, forwarding to the existing AppUpdater.check() used by the app menu. The daily-check caption was shortened. A real remote update offer was not tested.
- Settings defines a system window background and an explicitly visible toolbar background. A live before/after capture with the pointer moved onto the window title had zero changed pixels across the 25,220-pixel title region (`settings-title-comparison.log`).
- Three library rendering checks passed (`glass-refinement-tests.log`) and four Settings/update-channel/material/motion checks passed (`glass-settings-checks.log`). Final release build, RetroArch embedding and strict deep signature verification passed; validation app relaunched as PID 94042. Blue and warm artwork were visually checked; screenshots include `glass-refinement-blue.png`, `settings-update-button.png` and `settings-stable-title.png`.
- A separate app reopened from `NotProton/.claude/worktrees/cloud-build/out/Cartouche.app` as PID 91107. It was left running. Desktop verification explicitly targeted PID 94042 after discovering the duplicate.

The user rejected the reduced backdrop accent and removal of the top fade. Both were rolled back to the earlier appearance; `restore-backdrop-fade-build.log` and `restore-backdrop-fade-retroarch.log` passed, with strict deep signature verification. The validation app was relaunched. Further Liquid Glass work must focus on the left/right panes and upper controls, preserving the original background and fade. A native sidebar/inspector proposal based on Apple Landmarks was researched; it has not been applied.

2026-10-23 toolbar, continuous fade and installation presentation

- Replaced the custom header with a window toolbar. Add is immediately left of Search; Search follows the inspector's width calculation. Both retain glass. The native NSSearchField uses rounded bezel/large metrics inside its capsule. A real focused search for CarX produced one result, clearing restored the library, and the icon/text and rounded focus were visually checked (`search-rounded-focus.png`).
- Removed the rejected full-header safeAreaBar and the later material-overlay rectangle. Notices scroll with the library. After research and isolated SDK probes reproduced a hard cutoff, the final version uses one scroll-position opacity fade and hides the native toolbar backdrop/generated scroll edges. It is a deliberate visual fallback, not a claim of Apple's variable blur. Actual library scrolling shows the continuous fade without a rectangular band (`continuous-fade-scrolled.png`). CoverBackdrop is unchanged from the original artwork accent.
- Settings Steam has one content heading and a separate compact integration card. Update detail shows the version transition rather than repeated explanatory prose. Existing explicit quit/update labels, confirmation and manual-update behavior remain.
- Steam's preparing/queued state keeps the primary action's 38-point capsule height, with a round Cancel action. The actual component and Glass styles were rendered in an isolated preview at 300 and 400 points (`install-preparing-widths.png`); no live install was initiated by that preview.
- `continuous-fade-tests.log`: 21 tests in three suites passed, covering library states, Settings rendering and integration actions. The subsequent preparing/queued change is presentation-only and was qualified by the width preview and final release build. `fade-install-presentation-build.log` and `fade-install-presentation-retroarch.log` passed; strict deep signature verification passed. Validation app relaunched as PID 61274. The separate cloud-build copy PID 91107 remains running; target the validation path/PID explicitly when inspecting UI.
- The user withdrew the post-install runner report after identifying that it came from the other app version. No runner persistence change was made for that report. No game was force-quit for these visual changes.

2026-10-23 right inspector harmonization after Grok

- Reviewed Grok's unified PC/console panel. Kept its shared page and card composition; restored the runner selector and Steam preparing/queued installation component that its GamePanel replacement had dropped.
- PC and console artwork now use the same aspect ratio, aligning their title and primary-action baselines at equal inspector widths. Console saves follow Setup and Your Play, leaving those common sections in the same order.
- Runner, graphics, emulator, core and console look use the same 30-point menu treatment and 172-point control width. Narrow labels and runner revisions remain readable at 300 points. Runner options follow the current source-specific model lists, including the installed WineHQ Steam tools added by Grok. Available pinned downloads and Manage Runners are accessible from the runner menu; no live runner was downloaded during this change.
- Empty PC session cards use the same statistics columns as populated cards. Restored Steam preparation keeps the action capsule plus round Cancel presentation. Backdrop accent, library fade, toolbar glass and left sidebar were not redesigned.
- Corrected two reintroduced fixture expectations that claimed Linux online support; runtime anti-cheat policy was left unchanged.
- `panel-harmony-final-tests.log`: 40 tests across eight suites passed, covering PC/console/standalone panel states, inspector widths, statistics, runner choices, Steam tool registration and setup menus. Width fixtures now include an actual ready Cartouche runner and check the Graphics label; console controls are checked at 300/340/400 points. Snapshot artifacts are in `panel-harmony-snapshots`. Invisible-window native-glass PC captures do not reliably draw the header, so they are not evidence of a complete light-mode PC visual pass.
- Release build (`panel-harmony-build.log`), RetroArch embedding (`panel-harmony-retroarch.log`) and strict deep signature verification passed. Relaunched the validation app as PID 45295. Live CarX inspection confirmed its runner menu offers Cartouche Wine 26.3.0-2, Wine 11.0, Wine 11.18, an additional downloadable Cartouche revision and Manage Runners. Saved `panel-harmony-live-runner-menu.png`, `panel-harmony-live-carx.png` and `panel-harmony-live-console.png`. No game was launched or stopped, and no runner selection was changed during this UI inspection. The user was navigating the running app concurrently; stopped further UI input after observing that activity.

2026-10-23 Chained Together launch and per-attempt logs

- Found an actual Steam bridge failure in both D3DMetal and DXMT attempts: the Windows executables started, then the shim reported CreateSteamPipe failed and another Steam launch URL appeared. Downloaded runner preparation incorrectly claimed ntdll already carried the Steam hook. The inspected Cartouche Wine 26.3 files were unpatched.
- Added exact-hash x86_64/i386 loader hooks via the existing NtdllPatcher. The resolver now derives this build's frame-pointer load_path spill. Original engine DLLs are retained, only verified transitions update the runner receipt, and graphics clones invalidate when source ntdll changes. New app startup repaired the live Cartouche runner and DXMT clone; both x64 hashes are de2b6663..., with no receipt mismatches. Other unknown WineHQ builds are not covered by these pins.
- An isolated copied engine connected to native Steam through the Windows steamclient entry point after patching (pipe=1). Real application tests verified both binary patch outputs, idempotence, preserved originals and updated receipt verification. `chained-launch/final-tests.log`: 139 tests in 12 suites passed. `upgrade-tests.log`: 49 tests in five suites passed. A lifecycle fixture now uses the integration version constant instead of hardcoding revision 4.
- Added unique compatdata/cartouche-logs attempt directories (launch.log, wine.log), preserved old logs, recorded Wine launcher exit status and exposed Show Launch Logs in the Steam game menu. App.log now records Steam launch requests and selected runner/renderer. The cached game bundle receives its log directory through an environment variable. Shell syntax/lint, launcher lifecycle, bridge staging and independent log retention checks passed (`shell-checks.log`).
- Integration revision is now 0.1.0-5. Release build, RetroArch embedding and strict deep signing passed; validation app relaunched as PID 55990. Steam integration remains manual: the user answered that they are updating it, but the last observed install-build.json still says 0.1.0-4. Do not silently restart/reinject Steam. The new per-attempt script will activate after that update because the injected dylib owns and rewrites run scripts.
- Clicked Play for Chained Together in the new app at 17:51:30 local. Steam is currently waiting at ShowLaunchOption; the game has not launched in this post-fix trial. Native Steam GUI windows are owned by Steam Helper PID 98040 rather than steam_osx PID 97722. Opening steam://open/main produced a Steam Helper window whose captured pixels were black. Do not claim the game reaches its menu yet. Await the user's manual integration update, re-read process IDs, then resume the real launch test. No game was force-quit. Original logs are preserved in chained-launch/before; full diagnosis is docs/research/chained-together-launch.md.

2026-10-23 Steam activity, GOG details and current Wine revision

- User confirmed Chained Together launches after the preceding loader repair. This is user confirmation; no new game launch or forced game termination was performed for this follow-up.
- Steam console_log.txt GameAction/LaunchApp stages now feed launchingAppIDs. Reads reject earlier Steam sessions using the native client's process start time; completion, cancellation and failures clear preparation. The monitor clears launch state when Steam closes and polls each second while launching/running. ActivityCenter exposes preparation separately from an actual running game. Panel/card/menu show Launching…, block duplicate Play and runner/graphics/Wine writes during preparation, then expose Stop Game through the existing running-game detection.
- GOG's public product API supplies the panel header/screenshots. gogdl info supplies Windows base-game disk/download estimates, combining shared files with one language instead of every language pack. Metadata persists through refresh/restart and uses a separate GOG image cache namespace. No offline-installer download size is substituted for installed size.
- Runner download choices hide superseded uninstalled Cartouche Wine revisions. Installed older revisions remain manageable for games already using them; files and selections are preserved. WineHQ stable/development remain separate choices.
- Tests: gog-details/final-tests.log previously passed 44 tests in six suites. gog-details/final-steam-state-tests.log passed 87 tests in 16 suites, including new Steam preparation/session/menu tests, GOG persistence, runner choices, activity, media and console panels. One optional real RetroArch test skipped without its explicit environment. Updated an outdated ActivityQuit assertion to check Resume and Continue From without requiring them to be adjacent; ConsolePanelTests already documents Setup/Your Play between them.
- Release build, RetroArch embedding and strict deep codesign passed (gog-details/build.log and retroarch.log). Validation app relaunched as PID 20506; native Steam PID 45503 was left running. Live GOG panel displayed Cyberpunk screenshots/carousel controls and GOG · Not installed · ≈ 66,8 GB; evidence cyberpunk-live.png. Stopped further native UI input when concurrent navigation/window hiding became apparent. Latest-only runner choice and Steam launch transitions are covered by fixtures; no additional live game launch was triggered.

2026-10-23 Approved About copy

- Replaced the About panel's attribution/license paragraphs with the user-approved product copy: "Your games. Your Mac.", PC/console/library description, "Free and open source.", Website · GitHub. Website and the Cartouche repository are clickable; the headline is visually distinct within the native macOS About panel.
- Credits remain in README/NOTICE/LICENSE. Removed obsolete About translations and added the new copy in French, Italian and Simplified Chinese. Updated existing identity/localization expectations to match the approved copy.
- About-specific identity, repository attribution and localization checks passed: five tests in two suites (about-copy/focused-tests.log). The wider 17-test identity/localization run also found three unrelated existing expectations: Chinese trial-version fallback is now translated, a gatecheck fixture names SteamX, and SteamUpkeep has a takeover identifier outside the older allowlist. Those production paths/tests were not changed for this copy edit.
- User asked for a Ko-fi placement/copy proposal during the build. Suggested a secondary support row at the bottom of Settings > General, after Setup: Support Cartouche / If you enjoy Cartouche, you can support its development. / Support on Ko-fi. No donation UI or URL has been added pending their response.
- About release build, RetroArch embedding and strict deep codesign passed (about-copy/build.log, retroarch.log). User then said continue on Ko-fi; requested the missing destination URL before wiring a functional support link. The About build has not yet replaced the running process while that follow-up is underway.
- User said continue. Prepared SupportCartoucheSection(destination:) and FR/IT/zh-Hans strings, matching a standard grouped Settings row with a secondary external Ko-fi button. No destination is guessed and the section is not yet wired into General; the user's Ko-fi URL is pending via async input. These last support changes have not been built yet.
- Relaunched the already verified About release by terminating only the known validation Cartouche PID 20506. Steam was not restarted or stopped. The running binary contains the approved About copy; it does not yet contain the unbound Ko-fi section.

2026-10-23 Ko-fi link supplied and connected

- User supplied https://ko-fi.com/bryann2k. Wired the prepared SupportCartoucheSection into the bottom of Settings > General, after Setup. The grouped row uses the approved Support Cartouche heading, conditional support sentence and a secondary Support on Ko-fi external link. It opens the default browser; no HTML widget, payment flow, popup or launch prompt is embedded in Cartouche.
- Existing French, Italian and Simplified Chinese translations cover the three support strings. No separate tests were added for this reversible copy/link change; release compilation and native UI inspection are the relevant checks.
- Release compilation, RetroArch embedding and strict deep codesign passed (kofi/build.log, retroarch.log). Relaunched only Cartouche as PID 58049; native Settings window 5040 shows the full support row after Setup with the expected secondary button (kofi/settings-live.png). A coordinate click was sent to that button; the provider reported synthetic/unverified input, so browser navigation is not claimed as independently verified. The SwiftUI Link destination is the exact user-supplied HTTPS URL.

2026-10-23 User-requested complete runtime reset and Discord settings

- User explicitly requested uninstalling Cartouche, deleting its data and removing Steam injection to repeat a new-user installation. They subsequently requested the Discord invite in Settings. These are both part of the active scope; do not launch Cartouche or reinstall its Steam integration before the user begins their test.
- Stopped Cartouche PID 58049, then ran the built --remove-everything command. It gracefully stopped Steam, removed Cartouche's injection from outer and inner Steam bundles, restored the outer launcher with Valve's original signature, removed bridge/tools/update blocks, and retained user-game data as designed. Outer Steam strict signature verifies with Valve TeamIdentifier MXGJJ98X76.
- Completed the explicitly requested deeper reset: deleted the retained Cartouche installs/stores/console data, UI caches/cookies/logs/preferences, isolated Cartouche test preference files, and remaining Cartouche prefix-template folder/lock. Removed exactly the three Cartouche compatibility mappings from Steam config (1600530, 291550, 2567870), leaving other Steam settings intact. Removed the GOG sign-in using security delete-generic-password scoped to the Cartouche store service/account; subsequent Security queries found no Cartouche store/RetroAchievements records. Reset TCC All for dev.bryann2k.cartouche.
- The Eden installer had left its DMG mounted beneath ~/Applications/.cartouche-install-…/expanded. Matched the installed Eden executable to that staged image, detached the image, then deleted the Cartouche-installed Eden app and staging directory. It had no external settings folder. Observed both Eden Info.plists use an empty CFBundleExecutable although Contents/MacOS/eden exists; this was not changed during the reset and may warrant a separate emulator-packaging follow-up.
- Original imported game folders (including ~/Downloads/CarX Street), source ROMs, project checkouts/build sources and developer release-signing material under Cartouche-dev were preserved. Steam itself, its login and native library were preserved. macOS notification decisions are not guaranteed to reset with TCC; a separate macOS account is needed for an exact first-ever OS-permissions test.
- Added General Settings CommunitySection before Ko-fi: Discord / Get help and share feedback. / Join Discord, linking to https://discord.gg/fKxanZyFea. FR/IT/zh-Hans translations included. Release build, RetroArch embedding and strict deep app signature passed (discord-settings/build.log, retroarch.log). No UI launch was performed after the reset.
- Built ~/Downloads/Cartouche-0.1.0-fresh-install.dmg from the latest release app with packaging/dmg/make-dmg.sh. Reset evidence and metadata-only audit are in fresh-user-reset/; no token payloads were archived. The app remains closed and its runtime root/preferences must remain absent until the user launches it.
- Final metadata reset audit: 21 checks passed; fresh-user-reset/checks.json confirms absent app data/preferences/caches, no injection keys or deployed dylibs in either Steam bundle, no Cartouche compatibility tools/templates/choices/update block/bridge, and no running Cartouche/Steam. hdiutil verified the 94.4 MB fresh-install DMG.
- A supplemental strict signature check on Steam's internal cached client bundle reports "code has no resources but signature indicates they must be present"; that directory has no Contents/_CodeSignature. Do not describe the cached inner bundle as independently verified Valve-signed. The restored /Applications/Steam.app launcher does verify as Valve-signed. No extra Steam launch/update/re-sign was performed for this observation.


2026-10-23 Fresh onboarding fixes after the user reinstall

- Fixed controller Button glyphs and Layout options overflowing the onboarding card: both use stacked label/control rows with full available width. Extracted OnboardingControllerOptions for actual component rendering. Dark and light 612-point snapshots show both segmented controls fully inside the card (fresh-onboarding/snapshots/controller-options-dark.png and controller-options-light.png).
- Downloaded Cartouche Wine is now included in status capture. Runner downloads notify bootstrap to sync library runner choices and refresh system status; preparation failure is no longer treated as a successful onboarding download just because an archive receipt exists. Runner detail now says Cartouche Wine, preserving legal attribution elsewhere. The recommended build chooses the latest revision independently of manifest ordering.
- Confirmed installed integration was already 0.1.0-5: the false repair report checked downloaded Wine builtins under a phantom CrossOver clone directory. DeploymentContent now resolves the actual downloaded Wine root first. Real missing/changed builtins still fail integrity checking. RunnerSetup stages bundled Steam bridge builtins when a runner is prepared before the Steam onboarding step.
- Steam onboarding waits for runner preparation before installing integration and automatically opens Steam in the background afterward, with an explicit retry if opening fails. A failed preparation blocks this handoff. No global silent integration-update policy was added.
- qualified-tests.log: 91 tests in 11 suites passed, including fresh missing-bridge download, downloaded-root integrity checks, newest revision selection, runner completion refresh, automatic Steam handoff and preparation-failure blocking. These are isolated fixtures, not a complete live new-user walkthrough.
- Release build, RetroArch embedding and strict deep codesign passed (build.log, retroarch.log). Gracefully terminated only Cartouche PID 22961, staged and verified the replacement, then installed/reopened /Applications/Cartouche.app as PID 42656. The prior app is retained under fresh-onboarding/Cartouche-before-setup-fix.app. Steam PID 66755 was neither terminated nor reinjected; user data was preserved.
- Native inspection (live-main.json) found the resumed onboarding Consoles sheet. Did not advance the user through their setup or change their choices for QA. Full live new-user verification remains for their ongoing walkthrough.
- Updated DMG: /Users/user/Downloads/Cartouche-0.1.0-setup-fix.dmg. Qualification artifacts are under .scratch/qualification-0.1.0/fresh-onboarding/. No commit, push or runtime reset performed.
