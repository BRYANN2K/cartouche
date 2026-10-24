# Evidence: p10-store-integrations

Branch `phase/p10-store-integrations`, with main merged before the final checks (a4558df brings main 9b6714e: the P7 activity slot and P16 standalone emulators). Machine: Apple silicon, macOS 27.0, Xcode 27.0 (Xcode-beta.app), Swift 6.4.

How store tests run:

- legendary, gogdl, comet and nile are stood in for by shell scripts that answer as the pinned versions do, from their source at the pinned tags (argument parsers, the JSON they print, the files they write, their log lines). They record every call in `state/<client>.calls` and copy any token file they find to `state/<client>.saw-token`, so a test can tell what the vault put in place. Nothing signs in to a real store.
- The Keychain is `MemoryVault`, an in-memory `TokenVault`; the real Keychain is never touched. Each test gets a scratch library, scratch store folders and a scratch HOME; clients run with their own `HOME`, `TMPDIR` and config env (`StoreClientTests.ownEnvironment`).
- GOG's HTTP APIs (embed, account, gamesDB, remote config) are served by `StoreAPIServer` on 127.0.0.1 inside the test; nothing reaches the network.
- Games "run" on a fake CrossOver runner whose `wine` and `wineserver` are stub scripts that record their arguments; the test reads back the executable, the prefix and the backend env each launch used.
- Screenshots: `evidence/`, written by the tests with `CARTOUCHE_SNAPSHOTS`. They are offscreen captures: the selected row's tint and some filled shapes draw as plain dark boxes in them (the same limit as P5's and P13's evidence).
- This worktree's command shell is restricted: Vision's text recognition, WebKit's content process and any write outside the worktree (`~/Library/Caches` included) are denied. Every test that reads back a window as text (`renderedTexts`, `UIHost.texts`) therefore ends in `Caught error: .nilError` here, and `noPasswordField`'s web view never loads — 23 `.nilError` and ~50 window-size issues across main and P10 suites alike, all of the same three causes. The store windows still draw (that is how the screenshots below were regenerated after merging main); the same tests need the unrestricted `make -s app-tests` run to assert on them.

## Tests

| Suite | Result here | Notes |
|---|---|---|
| `swift test --no-parallel` in `app/` (restricted shell) | 1018 tests, 144 suites | failures are the 34 staged-payload baseline plus the blocked subsystems above; no P10 logic test fails |
| Store adapters (`StoreAdapterTests`) | 13 tests, all pass | sign-in codes, libraries, install/update/verify/launch/uninstall flags, expiry, save folders — per store |
| Store clients (`StoreClientTests`) | 7 tests, all pass | pins, refused pins, one-time download + hash check, re-fetch on change, own env, progress lines |
| Store sign-in (`StoreSignInTests`) | 7 of 8 pass | `noPasswordField`'s code half passes; its web-view half is blocked here (no WebContent process) |
| Store session expiry (`StoreExpiryTests`) | 3 of 4 pass | `expiredWindow` ends in the Vision `.nilError`; the three logic tests pass |
| Store games (`StoreGameTests`) | 8 of 9 pass | `storeCardTexts` ends in the Vision `.nilError`; `activitySlot` passes and draws the store-activity screenshots |
| Store imports (`StoreImportTests`) | 4 tests, all pass | .egstore, goggame info and fuel.json fixtures; a foreign folder is refused |
| Store cloud saves (`StoreSavesTests`) | 2 tests, all pass | two scratch libraries over one shared cloud; offline/expired play without sync |
| Store screens (`StoreUITests`) | 0 of 4 here | all four end in the Vision `.nilError`; they drew the evidence screenshots |
| `python3 -m unittest discover -s packaging/tests -p 'test_store_clients.py'` | 8 tests, all pass | pins valid, one per client, repo licenses, arm64-only assets, remote check contract |
| `python3 dylib/tests/l10ncheck.py … zh-Hans it` (what `make -s l10ncheck` runs) | 1110 strings | all translated for zh-Hans and it, except the one string main already leaves in English |
| `openspec validate p10-store-integrations --strict` | valid | – |

Store pins are checked against GitHub in CI by `.github/workflows/store-clients.yml`: `store_clients.py check` on every change of the pin file, and `verify --download` on a schedule, which fetches each pinned release asset and compares size and SHA-256 (needs the network, so it runs in CI, not here).

## Scenarios

### Sign in without seeing passwords / Epic sign-in
- Check: tests `StoreSignInTests.epicWithin15Seconds`, `epicCode` (adapter), `epicSignIn`, `tokenOnlyInVault`, `keychainItem`, `noPasswordField`, `signOut`, `sweep`, `overlappingRuns`; screenshots `evidence/store-page-epic-light.png`, `evidence/store-page-waiting-light.png`.
- Result: pass for the mechanism, with one maintainer step.
  - With the stub at pinned legendary's flags, once the page hands over the code the library lists the account's two Epic games in 0.29 s (limit 15 s). The code is read only from Epic's redirect page, traded for `user.json`, which goes to the vault and leaves the disk; `filesHolding` finds no file under the stores folder with a token in it, library and game records included. Tokens left by a crash sweep back into the vault at the next start.
  - The Keychain item is a generic password of Cartouche's own service, this Mac only, never synced. Sign out deletes it and asks the client to forget. Overlapping runs share one copy; the last one takes it back.
  - No `NSSecureTextField` anywhere in the app's code, and none in the drawn sign-in window (asserted in the unrestricted run; the window half is what this shell's WebKit block keeps from re-checking).
  - Maintainer step: connect a real Epic account once — the page must be Epic's, Cartouche must never show a password field, and the library must list the account's games within 15 seconds.

### Sign in without seeing passwords / Expired session
- Check: tests `StoreExpiryTests.expiredAtStart`, `expiredWhileRunning`, `playsWhenExpired`, `expiredWindow`, `StoreAdapterTests.epicExpired`; screenshots `evidence/store-expired-session-light.png`, `evidence/store-expired-session-dark.png`, `evidence/settings-accounts-stores-*.png`.
- Result: pass. A token past its end at start: the store reads expired, the sidebar badge is red, installed games stay playable — `playsWhenExpired` launches Sample Free Game offline, without Epic's sign-in code. A store that refuses the token mid-run turns expired, and comes back after signing in again. The window screenshot shows the banner "Your Epic Games session expired / Your games still play. Sign in again to download and update them." with Sign In Again, the games still listed. Settings > Accounts shows the same row in red with Sign In Again.

### Store games behave like Steam games / Install and play
- Check: tests `StoreGameTests.epic` (`activity slot fractions while Sample Free Game downloaded: [0.0, 0.125, 0.5, 1.0]`; the game then started with runner 27.0.0.40921 and DXMT, in its own prefix, under Rosetta), `gog`, `amazon`, `manage`, `storeCover`, `rosettaOnly`, `noRunner`, `activitySlot`; screenshots `evidence/store-activity-light.png`, `evidence/store-activity-dark.png`.
- Result: pass for the mechanism, with one maintainer step. A free Epic game downloads with progress in the sidebar's shared activity slot (the store job takes the slot after playing and installing and before Steam downloads, drawn in the screenshot), then launches from `legendary launch`'s answer with the runner and backend of its setup. GOG starts from its goggame info with comet beside it; Amazon from fuel.json. Update, verify and uninstall go through the store's client; uninstall removes the files and the prefix, cloud saves stay with the store. Without a runner, Play names Settings > Compatibility.
  - Maintainer step: install and play one real free game per store (a real account is needed for each).

### Store games behave like Steam games / Cloud saves
- Check: tests `StoreSavesTests.twoMacs`, `offline`, `StoreAdapterTests.epicSaves`, `gogSaves`.
- Result: pass for the mechanism, with one maintainer step. Two scratch libraries share one stub cloud: the save written on the first "Mac" is in the second's prefix when the game starts there (3.5 s end to end). Offline or expired, the game starts without syncing and syncs again once online. Epic's save folder is resolved inside the game's prefix and synced each way; GOG's locations come from the remote config and gogdl's sync time is kept.
  - Maintainer step (needs two real Macs): play a GOG game with cloud saves on Mac A, quit, then launch it on Mac B — the save made on A is there.

### Honest capability list / Amazon
- Check: tests `StoreAdapterTests.amazonCapabilities`, `StoreUITests.amazonPage`, `epicAndGOGPages`, `waiting`, `accounts`; screenshots `evidence/store-page-amazon-light.png`, `evidence/store-page-amazon-dark.png`, `evidence/store-page-amazon-macos15-light.png`, `evidence/store-page-amazon-macos15-dark.png`.
- Result: pass. With nile pinned at 1.2.0 the Amazon page lists Cloud saves and Online features each as "Not supported yet", downloads/update/verify as supported; the Epic and GOG pages name what their clients do support ("Depends on the game" for Epic online features, "Achievements and friends, through comet" for GOG). The pages are drawn in light and dark on the macOS 26 look and on macOS 15's.

## Left for the maintainer

- A real sign-in per store (Epic, GOG, Amazon), one real free game installed and played per store, and the two-Mac cloud-save run above: the tests prove the mechanism against the clients' pinned behavior, but no test signs in to a real account.
- THIRD-PARTY-LICENSES still names legendary, gogdl, nile and comet under "planned for later phases": the docs agent's pass (task 4.1).
