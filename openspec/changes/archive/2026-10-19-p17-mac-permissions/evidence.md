# Evidence: p17-mac-permissions

Branch `phase/p17-mac-permissions`, from main a81a5b1. Machine: Apple silicon, macOS 27.0 (26A428), Swift 6.4.

No test reads or changes the real TCC database. Every state comes from `FakeTCC` (`app/Tests/NotProtonAppTests/PermissionMocks.swift`), every System Settings link goes to an injected opener, and nothing relaunches for real (`FakeRelauncher`). `PermissionCenter` has no default opener, so a test cannot reach `NSWorkspace` by mistake.

The package has no XCUITest target, so the "UI tests" of tasks 1.2, 2.3 and 2.4 drive the same view models the views bind to, and render each view offscreen (`NSHostingView`, light and dark) into `evidence/`. Run them again with `CARTOUCHE_SNAPSHOTS=<folder> swift test --filter "Permission|Steam step|Relaunch|Gated|Privacy"`.

## Tests

| Suite | Before (main a81a5b1) | After |
|---|---|---|
| `make -s app-tests` | 554 tests, 34 fail (43 issues) | 612 tests, the same 34 fail (43 issues) |
| Hermetic C suites from `app.yml` (19) | all pass (P0 evidence) | 19 pass; no C, shell or JS file changed |
| `make -s l10ncheck` | 433 strings, 1 left in English | 507 strings, the same 1 left in English |
| `openspec validate p17-mac-permissions --strict` | – | valid |

- The 34 failing Swift tests need the staged payload ("This build carries no components at all"). The list of failing test names is identical before and after.
- 58 new tests (a parameterized test counts once). No test was deleted or skipped, and no existing test was changed.
- `runcheck` and `scriptcheck` were not run: shellcheck is not installed here, and no script changed.
- New suites, all in `app/Tests/NotProtonAppTests/`: "Permission catalog", "Permission probe file checks" (`PermissionCatalogTests.swift`), "Permission request flow" (`PermissionFlowTests.swift`), "System Settings links" (`SettingsLinkTests.swift`), "Steam step" (`SteamStepTests.swift`), "Settings > Privacy" (`PrivacySettingsTests.swift`), "Options that need a permission", "When permissions are asked" (`GatedOptionTests.swift`), "Relaunch" (`RelaunchTests.swift`), "Permission scan" (`PermissionScanTests.swift`).

## Where the module plugs in

The module is in `app/Sources/NotProtonApp/Permissions/`. The screens that use it come in later phases, so the module is complete but not yet reachable from the running app (the release binary does not even link its live requester yet, see "Unused permissions are never requested"):

- Settings > Privacy: `PrivacySettingsView(center:)`, hosted by the Settings window of P5.
- Onboarding Steam step: `SteamStepRow(step:)` and `SteamStep`, used by P18. Its install closure is `SystemStatus.installIntoSteam`'s work, its relaunch closure is `RelaunchService.relaunch(to:)`.
- Options that need a permission (Downloads in P6 and P18, removable folders in P13, netplay in P14, key remapping and Accessibility in P15, notifications in P7): `GatedOption` and `GatedOptionRow`.
- Notifications: P7 calls `NotificationOffer.offer(after: .downloadFinished | .installFinished, flow:)`.
- Relaunch: P15 and P18 call `RelaunchService.watch(_:route:)` on their flow, show `RelaunchBanner`, and call `restore()` once at launch.

## Scenarios

### Ask only when needed, explain first / Notifications are not asked at launch
- Check: test `PermissionMomentTests.notificationsAfterFirstFinish` ("Notifications are not asked at launch, only after the first download or install, after the explanation"); test `PermissionMomentTests.launchAsksNothing`; test `PermissionMomentTests.rule`; test `PermissionScanTests.promptsOnlyFromTheModule` (no prompt API outside `Permissions/`, so nothing at launch can reach one); screenshot `evidence/explain-notifications-light.png`, `-dark.png`.
- Result: pass. After `.launch`, no sheet and 0 requests. After `.installFinished`, the sheet shows ("Get a notification when a game is ready?") with 0 requests; only Continue makes 1 request. A later `.downloadFinished` offers nothing again.
- Not covered here: the real first launch of the app. The app has no download or install notification yet (P7), and `UNUserNotificationCenter` is never called outside the module.

### Ask only when needed, explain first / Unused permissions are never requested
- Check: test `PermissionScanTests.usageDescriptions`; test `PermissionScanTests.noUnusedPermissionAPIs`; command `plutil -p out/Cartouche.app/Contents/Info.plist | grep UsageDescription` on the bundle from `make -o app-payload app`; command `nm -u app/.build/release/NotProtonApp | grep -ciE "AVCapture|CBCentral|CBPeripheral|SCShareable|SCStream|CGRequestScreenCapture|CGPreflightScreenCapture|CGWindowListCreateImage"`; command `otool -L` on the same binary.
- Result: pass. Info.plist has exactly three usage descriptions, each for a catalog permission: `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSLocalNetworkUsageDescription`. None for camera, microphone, Bluetooth, screen capture, Desktop, Documents, network volumes, Apple Events. No source names a camera, microphone, screen recording, Bluetooth or Full Disk Access API or pane. The binary has 0 such symbols and links none of AVFoundation, CoreBluetooth or ScreenCaptureKit (linked: Accessibility, AppKit, CoreFoundation, CryptoKit, Foundation, Sparkle, SwiftUI; Accessibility.framework is SwiftUI's accessibility notifications, not the TCC service).
- The three usage strings are translated (`Resources/Localization/InfoPlist.xcstrings`, compiled to `<lang>.lproj/InfoPlist.strings`, which `make app` copies into the bundle): test `PermissionScanTests.usageTranslated`; `plutil -p out/Cartouche.app/Contents/Resources/it.lproj/InfoPlist.strings`.

### Clear state and recovery / Recover App Management
- Check: test `PrivacySettingsTests.recoverAppManagement`; test `PrivacySettingsTests.listSnapshot` (the text snapshot of every row); test `PermissionCatalogTests.activationNotification` (the real `didBecomeActiveNotification` path); test `SettingsLinkTests.privacyPanes`; screenshot `evidence/privacy-light.png`, `-dark.png`; command `open "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"` on this Mac (macOS 27).
- Result: pass on the model. The App Management row reads "Not allowed" with Open System Settings. Open System Settings opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles` and marks App Management for a recheck. When Cartouche becomes active again, one write check runs (`deepReads == [.appManagement]`) and the row reads "Allowed", in the same `PermissionCenter`, without a restart.
- Every row shows its feature and one of Allowed, Not allowed, Not asked yet, or "Unknown, will be asked when needed" for the grants Cartouche cannot read (Steam's Accessibility, the games' Input Monitoring, Local Network once asked).
- The manual open on macOS 27 exited 0 and brought System Settings to the front. Seeing that it lands on App Management needs eyes on the screen: manual check M2.

### Denied never means silent failure / Downloads denied
- Check: test `GatedOptionTests.downloadsDenied`; test `GatedOptionTests.downloadsDeniedInPrompt`; test `GatedOptionTests.othersUnaffected`; screenshot `evidence/denied-downloads-light.png`.
- Result: pass. With Downloads denied, turning on "Suggest installers that appear in Downloads" leaves it off, with "Cartouche can't read Downloads. Allow it in System Settings." and an Open System Settings button, and no prompt (macOS will not ask twice). A denial in macOS's own prompt ends the same way. Other options still turn on.
- Partial: "drag and drop of an installer still works" can only be checked once P6 adds the drop target. Here the option row says "Dragging an installer onto Cartouche still works." and nothing in the module can block a drop: the Downloads permission is read only by `GatedOption(.downloads)`. P6 should add a test that drops an installer with Downloads denied.

### Denied never means silent failure / Steam modification denied
- Check: test `SteamStepTests.fixtureIsAppManagement` (NotProton's `WriteRefused` and `Remedy` read the fixture as App Management); test `SteamStepTests.deniedDuringOnboarding`; screenshot `evidence/steam-step-blocked-light.png`, `-dark.png`.
- Result: pass on the model. The install is a real write into a fixture `Steam.app` whose `Contents/MacOS` is read-only. The Steam step shows the explanation first, then "macOS blocked the change. Allow Cartouche in App Management, then try again." with Open System Settings (opens `Privacy_AppBundles`) and Try Again. `canContinue` stays true, so consoles and folders can go on. The onboarding screens themselves come in P18.

### Permissions survive updates / Update keeps grants
- Check: not run. It needs two builds signed with P9's stable self-signed identity, and real grants.
- Result: needs manual check M5, after P9 lands. Nothing in this phase changes the signature or the bundle identifier.

### Relaunch handled by Cartouche / Quit and Reopen
- Check: test `RelaunchTests.quitAndReopen`; test `RelaunchTests.reopenHelper`; test `PermissionFlowTests.beforePromptHook`; screenshot `evidence/explain-inputMonitoring-light.png`, `-dark.png`.
- Result: pass on the model. The explanation says "macOS applies it after Cartouche relaunches, which takes a few seconds." before the prompt. The Controls route (`controls`, `Hades`, finishing Input Monitoring) is saved right before the prompt, because macOS's Quit & Reopen gives no warning. A new copy of the module on the same defaults restores that route once, turns remapping on, and the request count stays 1: no second prompt. Restoring took well under 5 seconds.
- The reopen helper (`/bin/sh` that waits for the old pid, then runs `open -n` on the bundle) was measured with a stand-in process and `touch` instead of `open`: it waited for the old process, then ran in under 5 seconds.
- Not measured: a real Cartouche relaunch, which would quit a running app. Manual check M3.

### Relaunch handled by Cartouche / Later
- Check: test `RelaunchTests.later`; test `RelaunchTests.deniedInstead`; screenshot `evidence/relaunch-later-controls-light.png`, `evidence/relaunch-later-light.png`, `-dark.png`.
- Result: pass on the model. After Later, the banner reads "Relaunch Cartouche to finish", "macOS applies Input Monitoring after a relaunch. Your game and settings stay as they are.", with a Relaunch button. The option reads "Waiting for a relaunch" and stays off. Nothing relaunches until Relaunch is clicked, and another option (Notifications) still turns on. If the user denied instead, no banner shows and the option says "Cartouche can't read the keyboard. Allow Input Monitoring in System Settings."

### Relaunch handled by Cartouche / Game running
- Check: test `RelaunchTests.gameRunning`; test `RelaunchTests.cancelWhileWaiting`; screenshot `evidence/relaunch-game-running-light.png`.
- Result: pass on the model. With a game running, Relaunch waits (`phase == .waitingForGame`, 0 relaunches) and the banner reads "Cartouche relaunches when your game quits". When the game quits, Cartouche relaunches once and the saved screen is there to restore. Cancel stops the wait without relaunching.
- A game counts as running when a process runs from one of Cartouche's runner clones (`RunnerInstaller.isRunning`, which NotProton already uses to refuse updates during a game). Console games (P12) need their own `GameActivity` check.

### No relaunch during onboarding / Onboarding permissions
- Check: test `PermissionMomentTests.onboardingPermissions`; test `PermissionCatalogTests.inventory`.
- Result: pass on the model. In the onboarding context the flow lets through only App Management and Downloads, refuses every other permission, and neither of the two needs a relaunch. The only permission that needs one is Input Monitoring. The onboarding screens come in P18; manual check M4 runs it end to end.

### No relaunch during onboarding / App Management not yet applied
- Check: test `SteamStepTests.notYetApplied`; test `SteamStepTests.allowedThenTryAgain`.
- Result: pass on the model. App Management reads Allowed after the user comes back from System Settings, yet Try Again still gets the fixture's write refusal: the step says "macOS still blocks the change. If you allowed Cartouche in App Management, relaunch Cartouche to finish." and offers Relaunch Cartouche, which saves the route `onboarding` / `pcGames` for the relaunch to reopen on. When the write goes through, the step finishes.

## Deep links (task 1.3)

- Check: test `SettingsLinkTests.privacyPanes` (macOS 15 and 26), `otherPanes`, `fallback`, `exactOnly`, `remedyLink`.
- Result: each permission builds `x-apple.systempreferences:com.apple.preference.security?<anchor>` (`Privacy_AppBundles`, `Privacy_Accessibility`, `Privacy_ListenEvent`, `Privacy_FilesAndFolders`, `Privacy_LocalNetwork`), then the Privacy & Security root. Notifications opens `com.apple.Notifications-Settings.extension?id=<bundle id>`, Login Items `com.apple.LoginItems-Settings.extension`, both with System Settings itself as the fallback. A link that does not open falls back to the next. `SettingsLink.brokenAnchors` takes a major version's broken anchors without other code changes.
- NotProton's App Management remedy (`Remedy.settingsPane`) now uses the same link. It used `com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles`; design.md names `com.apple.preference.security?Privacy_…`, which is what both use now.
- Not done: opening each link on macOS 15 and 26. Manual check M2. Task 1.3 stays unticked for that reason.

## Which permissions apply without a relaunch (task 2.5)

Needs manual check. Measuring it means granting real permissions, which this phase must not do on this Mac. Expected values come from Apple's documentation and the design; every cell is unconfirmed.

| Permission | How to see it applied, in the same process | Expected | macOS 15 | macOS 26 | macOS 27 |
|---|---|---|---|---|---|
| App Management | Steam step Try Again writes into Steam.app | live | needs manual check | needs manual check | needs manual check |
| Accessibility (Cartouche) | `AXIsProcessTrusted()` is true and a posted key event arrives | live | needs manual check | needs manual check | needs manual check |
| Input Monitoring (Cartouche) | an `IOHIDManager` or listen-only event tap receives a key press | relaunch | needs manual check | needs manual check | needs manual check |
| Downloads | listing `~/Downloads` succeeds right after Allow | live | needs manual check | needs manual check | needs manual check |
| Removable Volumes | listing the external folder succeeds right after Allow | live | needs manual check | needs manual check | needs manual check |
| Local Network | a Bonjour browse finds a LAN peer right after Allow | live | needs manual check | needs manual check | needs manual check |
| Notifications | a test notification shows right after Allow | live | needs manual check | needs manual check | needs manual check |
| Login Items | `SMAppService.mainApp.status` is `.enabled` | live | needs manual check | needs manual check | needs manual check |

Method, per macOS version, on a test user account (never the maintainer's daily account):

1. Build the app with `make -o app-payload app` and copy `out/Cartouche.app` to `/Applications`.
2. Reset Cartouche's grants for the services under test: `tccutil reset SystemPolicyAppBundles dev.bryann2k.cartouche`, then the same with `Accessibility`, `ListenEvent`, `SystemPolicyDownloadsFolder`, `SystemPolicyRemovableVolumes`. Notifications: remove Cartouche in System Settings > Notifications. Login Items: `sfltool resetbtm` (resets every login item of the account). Local Network has no reset; use a fresh account.
3. Open Cartouche. For each permission, start its feature so Cartouche's sheet and then macOS's prompt appear, allow it (in the prompt or in System Settings), and switch back to Cartouche without quitting it.
4. Run the check in the second column without quitting Cartouche. Record "live" if it works now, "relaunch" if it works only after Cartouche is quit and reopened.
5. Fill the cell, and if a result differs from "Expected", change `Permission.needsRelaunch` in a follow-up change.

Until P15 and P5 exist there is no screen that starts each feature. The quickest way for the maintainer before then is a debug build that calls `PermissionCenter.live().request(_:)` from a menu item; it is not in this branch.

## Manual checks for the maintainer

- M1. Recover App Management end to end, once P5 hosts Settings > Privacy: deny App Management (onboarding or Install), open Settings > Privacy, click Open System Settings next to App Management, allow Cartouche, switch back. The row reads Allowed without quitting Cartouche.
- M2. Deep links on macOS 15 and 26: for each Open System Settings button in Settings > Privacy, the pane named in "Deep links" opens (App Management, Accessibility, Input Monitoring, Files and Folders, Local Network, Notifications for Cartouche, Login Items). On macOS 27 the App Management link was opened once from the terminal and System Settings came to the front; the pane itself was not checked.
- M3. Quit & Reopen, once P15 has Controls: turn on key remapping, Continue, allow Input Monitoring, click Quit & Reopen. Cartouche reopens on the same Controls screen within 5 seconds with remapping on and no second prompt. Repeat with Later: the banner and "Waiting for a relaunch" show; click Relaunch. Repeat with a game running: the banner says it waits, the relaunch happens after the game quits.
- M4. Onboarding, once P18 exists: complete it with every option on. The only macOS prompts are App Management (as macOS's block notification) and Downloads, and Cartouche is never asked to quit.
- M5. Update keeps grants, once P9 signs with the stable identity: install v0.1.0, allow Accessibility and Notifications, update to v0.1.1 through Sparkle. Both stay allowed with no prompt. Check first that `codesign -d -r- Cartouche.app` prints the same designated requirement for both builds.
- M6. The matrix above.
