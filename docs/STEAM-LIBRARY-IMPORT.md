# Steam library import and integration updates

Cartouche imports the signed-in account's owned games automatically. It reads an authenticated export from the running Steam library and merges local installation manifests. It watches for new exports; importing requires no file selection or separate Steam Web login.

Changing the integration installed inside Steam is a separate, manual operation in **Settings → Steam**. The screen shows the installed integration revision and the revision included with the app. Opening Cartouche, activating its window, and quitting Steam only check the installed state. They never install or repair the integration. An explicit installation/update/repair action retains the existing confirmation before quitting Steam.

The integration revision is `CARTOUCHE_STEAM_INTEGRATION_VERSION` in `cartouche_identity.h`. It is written to `install-build.json`; older records without the field are displayed as Legacy. Application version ordering still prevents an older app from overwriting a newer installation.

## First installation

Onboarding recommends the newest bundled Cartouche Wine revision. Downloading it includes preparing the runner; an archive receipt alone does not count as successful setup. Preparation stages the bundled Steam bridge if it is not present yet, because the Windows Games step can run before the Steam step.

When the user sets up the Steam integration, onboarding waits for runner preparation to finish. A preparation failure blocks installation and is shown for retry. After successful integration setup, Cartouche opens Steam in the background so its library export can load. An opening failure offers an Open Steam retry. This handoff follows the user's setup action; ordinary app activation still does not install or repair the integration.

Completing a runner download refreshes the library's runner choices and system status. Integrity checks resolve downloaded Wine's actual installation directory before considering a CrossOver clone. This avoids false missing-file reports while still detecting damaged or absent bridge files. The user-facing runner description uses Cartouche Wine; upstream attribution remains in the repository's license and credit documents.

## Findings from related projects

Reviewed on 2026-10-22:

- [Sevoflurane](https://github.com/kageroumado/sevoflurane/tree/2df6f9b3e12814b436d5bbf1d84a2bb772398236), especially `SteamWebHost.swift` and `SteamLibraryCompat.swift`: it hosts Windows Steam, polls while the app store loads, and reads `appStore.allApps`. Its installed-game list uses `local_per_client_data.installed`; the general `installed` flag can include another machine. Cartouche now also retries if its initializer runs before the app store exists, supports that public collection, and prefers the local installation flag. Ownership filtering remains required.
- [Soju](https://github.com/BCD1210/soju/tree/43ed224336cdffdba9dc4b47aa858a5273eb0838), especially `resources/steam-library.js`: its owned library comes from an authenticated Steam Web session and `GetOwnedGames`, with account and completeness checks. This is a different sign-in architecture. Local metadata caches alone do not prove ownership, so Cartouche does not import every cached app as an owned game.

## Local failure observed

The running integration logged a refusal to register Cartouche's export routes because Steam's `TransportValidationClient.AddNumbers#1` and `TransportAuth.Authenticate#1` carried the same flags. No `steam-library.json` was created. The integration branch already contains the route-registration correction; replacing the old loaded integration requires the explicit Settings action and a Steam restart.

The exporter still authenticates its transport and obtains the per-launch export token through that transport. The receiver verifies the token. Neither the new readiness polling nor the manual update policy removes these checks.

## Other changes in this validation build

- FSEvent stream creation and shutdown run on the folder watcher’s serial queue. A live process sample showed `FSEventStreamCreate → watch_path → open` blocking the main thread during startup; moving that work off the UI thread keeps unavailable watched folders from freezing the app. The initial console folder scan also runs independently of controller, runner and store startup.
- Only the game panel's Wine Tools group is hidden; Controls remains visible. Wine tools remain available in the game's menu.
- GPU comparison profiles ship with the app, so existing MacGamingDB reports can produce per-Mac estimates and populate the Mac picker even when the separate compatibility feed is unavailable. Missing reports still produce no estimate.
- **Settings → Runners → Check for Updates** bypasses the daily check interval and daily-check preference for that explicit request. Manifests still require their EdDSA signature. Installing each runner update remains an explicit action.

The remote runner manifest currently requires the maintainer setup in `docs/RELEASE.md` (Runner manifest): publish the signed `manifest` release using the existing Sparkle key. An unavailable feed is reported in the UI and does not change installed runners. The public `wine-crossover-26.3.0-2` release is a prerelease and is not silently promoted into this app's bundled catalog.

## Verification

`make webpatch-fixtures panel-behavior webuicheck libexport-check` passes, including delayed app-store readiness, local versus remote installs, transport authentication, export token checks and the receiver round trip.

Focused Swift runs passed (87 tests in 10 suites; 42 tests in 7 suites; and a final installer/status pass of 99 tests in 9 suites, with overlapping coverage). They cover integration status, manual update policy, explicit integration revisions, compatibility estimates, runner catalog refresh, signature validation, automatic file-watcher import, runner migration and rendered game panels. The release app compiled successfully; all 35 staged payload files match the bundled copies, and deep signature verification passed after embedding RetroArch. The explicit Settings update was exercised on this Mac. After restarting Steam, the live export contained 156 owned games, and Cartouche automatically changed from 3 to 159 games without an import action. The first manual run also exposed a final-verification ordering bug: checking the new integration against the previous build record prevented recording success. Final verification now receives the completed transaction’s build and still checks the installed bytes before writing the new record. The subsequent manual run completed successfully: `install-build.json` records integration `0.1.0-2`, the Settings screen reports “Cartouche successfully installed”, and the outdated-integration banner is gone. Steam was reopened and Cartouche’s Steam tab shows 156 games.

A live UI check confirmed the Wine Tools group is absent while Controls remains present, CarX Street shows a 53 fps estimate from two comparable reports, and the runner update button reports the unavailable signed feed. The background folder watcher regression test also passes with actual FSEvents delivery.

## Background installation and runner changes (0.1.0-4)

Cartouche starts a closed Steam with `-silent` and a non-activating workspace configuration. Its install worker leases only the selected app's install-manager events. A guarded `RegisterForShowInstallWizard` callback leaves that app's wizard hidden while Cartouche selects the library, disables shortcuts and presents license agreements in its own sheet. Other Steam installations retain their normal UI. The lease expires after five minutes and ends on completion, cancellation or failure. If the callback anchor changes, the worker refuses the operation before opening the wizard. Older integrations require the manual Settings update before Cartouche submits a new installation command.

Switching between compatible Wine runners reuses `steamapps/common/<game>` and `compatdata/<appid>/pfx`. The previous-build receipt is now diagnostic information, rather than a reason to refuse launch and request a prefix rebuild. Prefix locking and architecture checks remain. Switching the Mac/Windows edition still selects different platform files.

GOG, Epic and Amazon already store downloaded files under a stable game folder and keep the Wine prefix beside it. Their selected runner is resolved at launch; changing it does not call the store's installation API. Windows installer games rewrite their existing launcher. No game-content folder is copied for a runner change, and saves remain in the same prefix.
