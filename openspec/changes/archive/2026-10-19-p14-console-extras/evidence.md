# Evidence: p14-console-extras

Branch `phase/p14-console-extras`, with main merged in (P7 activity, P8 performance, P16 standalone emulators). Machine: Apple silicon, macOS 27.0, Swift 6.4. The agent run happened in a write-restricted shell, so the checks that need Vision text recognition, a window server sized like a real screen, Valve's servers, hdiutil or the staged payload could not finish here; what each such check shows is noted per test. Everything below names the command, the test or the picture to look at.

How the tests run:

- No real RetroArch binary, core, iCloud Drive, Keychain or RetroAchievements account is touched. RetroAchievements is stood in for by recorded API answers (`AchievementsClient` with a fixed reply per `r=` request) and, in RetroArchKit, by `AchievementsServer`, a loopback HTTP server that answers like `dorequest.php`. The Keychain is `MemorySecrets`, a dictionary. The "lobby" answers recorded JSON like `lobby.libretro.com/list` returns. iCloud Drive is a scratch folder, and "the other Mac" is a second `RetroArchPaths` root looking at the same folder. Netplay on one Mac is two RetroArch processes on 127.0.0.1.
- Every test makes its own scratch folder and removes it afterwards. Nothing is written under the real `~/Library`, `~/Documents` or the user's emulators.
- The game file is a 19-byte "Test Cart" written by the test (three bytes of header, then `CARTOUCHE TEST`), plus a 5-line Game Boy-looking file where a hash is needed. Neither contains a byte of any published game.
- Screenshots are in `evidence/`. They are offscreen captures, so in dark mode some controls draw as on a light window, as in P5, P13 and P16.

## Tests

| Check | Command | Result |
|---|---|---|
| RetroArchKit unit tests | `swift test --package-path retroarch --no-parallel` | 142 tests in 25 suites, 4 issues, all environmental: 2 × `ConsolesSettingsTests` need the `RetroArch_Metal.dmg` fixture the buildbot tests stage (`make retroarch-rig`); 2 × `StandaloneSettingsTests` (P16) die in `VNImageRequestHandler.perform` with `Foundation._GenericObjCError.nilError` — Vision OCR does not run in this shell (a scratch render of "HELLO" fails the same way). No P14 suite failed. |
| P14 unit tests only | `swift test --package-path retroarch --filter 'NetplayTests\|AchievementsTests\|ConsoleExtrasTests\|CloudSavesTests\|CoachTests\|ExtrasIntegrationTests'` | 21 tests in 5 suites, all pass; the 4 rig-gated tests skip with "set CARTOUCHE_RETROARCH and CARTOUCHE_TEST_CORE". |
| App tests | `cd app && swift test --no-parallel` | 974 tests in 137 suites, 128 issues. Every failure is in a category the shell cannot run: 48 `LibraryWindowTests` window-size/Vision expectations, 25+7+4 Valve network ("could not reach Valve's servers" / denied writes to the real `~/Library/Caches`), 17 `appinfo` helper + 1 payload fixture needing `make` artifacts, ~28 Vision `nilError` across the console/UI suites (includes the 4 panel tests below), 3 `hdiutil` denials, 1 `ImageRenderer`/CoreImage nil (`RevealTests`), 1 timing (`Watched folder … within 10 seconds`). None touches the P14 code path. |
| P14 panel suite | `cd app && swift test --filter ConsoleExtras` (also inside the full run above) | 6 tests: `hostAndJoin` and `coachRelay` pass; the other 4 fail only at the `VNImageRequestHandler.perform` call (`.nilError`, same environmental Vision failure). Their logic assertions before rendering pass — see each scenario. |
| App build (release) | `swift build --package-path app -c release` | Build complete, 69.6 s. |
| `l10ncheck` (app catalog) | `python3 dylib/tests/l10ncheck.py app/…/Localizable.xcstrings <intermediates> zh-Hans it` | 1081 strings, all translated for zh-Hans and it, except the one string main already leaves in English ("The trial version is not supported."). The stale entry "Covers from libretro-thumbnails." (replaced by P14's longer caption) was removed so sync stays clean. |
| `retroarch-l10ncheck` | `python3 dylib/tests/l10ncheck.py retroarch/…/Localizable.xcstrings <intermediates> zh-Hans it` | 79 strings, all translated. |
| `openspec validate p14-console-extras --strict` | – | "Change 'p14-console-extras' is valid". |

## Scenarios

### Netplay — Host and join

- Check: `NetplayTests` (RetroArchKit, 6 tests, all pass) and `ConsoleExtrasPanelTests.hostAndJoin` (app, passes).
- Result: `center.host(game)` produces a `PlayRequest` with `netplay == .host(port: 55435, announce: true)` and `netplayNickname == "player42"`; `hostAndJoinAreRetroArchsOwnFlags` and `aHostedGameIsAnnouncedThroughTheRelayWithTheNickname` check the appended config carries RetroArch's own `--host`/announce flags and the nickname (`netplay_use_mitm_server = true`, `netplay_nickname = player42`).
- Join: `theLobbyIsAskedForItsList` asks `http://lobby.libretro.com/list`; `lobbyRoomsJoinThroughTheRelayOrDirectly` turns a recorded room into `.join(NetplayTarget(address: "198.51.100.20", port: 55436, session: "abcdef"))` — the MITM relay endpoint when the host announced one. `aRoomIsTheGameOfTheLibraryWithTheSameFileAndACoreOfItsConsole` keeps only rooms whose `game_name` matches a library file on a matching core, and counts the rest as "other games". `aLocalRoomReadsRetroArchsBonjourRecord` parses a recorded `_ra_netplay._tcp` TXT record for the same-network list.
- The panel: `evidence/p14-panel-achievements-*.png` shows "Play Together / Netplay — Host, Join…".
- Within 10 seconds: `NetplayIntegrationTests.hostAndJoinWithinTenSeconds` runs two real RetroArch on 127.0.0.1 and asserts "You have joined as player 2" / "player-b has joined as player 2" inside 10 s. Rig-gated — see maintainer step 1.
- Not covered here: two physical Macs on one network and the real lobby. See maintainer steps.

### RetroAchievements — Counts match the site

- Check: `AchievementsTests` (6 tests, all pass), `ConsoleExtrasTests.signInOnceThenCountsPerGame` and `aWrongPasswordSaysWhy` (pass), `ConsoleExtrasPanelTests.countsAfterSignIn` (logic passes; the `seen("12 of 64")` line needs Vision).
- Result: signing in sends the password once (`signingInKeepsTheTokenAndSendsThePasswordOnce` — the recorded `login2` answer is `Success`, token `Q1w2E3r4T5y6U7i8`) and stores only the token (`secrets.all == ["player42": "Q1w2E3r4T5y6U7i8"]`). A recorded `allprogress` answer `{"228": {"Achievements": 64, "Unlocked": 12, "UnlockedHardcore": 7}}` becomes "12 of 64" in the panel (`countsAreTheSitesForTheAccount`, `signInOnceThenCountsPerGame`); before refresh it reads "Not known yet", before sign-in "Not signed in". A wrong password surfaces the site's `Error` (`aWrongPasswordSaysWhy`). `cartridgesAreHashedAsRcheevosDoes` checks the game hash matches rcheevos' scheme.
- The panel: `evidence/p14-panel-achievements-*.png` reads "Achievements 12 of 64"; `evidence/p14-settings-signed-in-*.png` reads "RetroAchievements — Signed in as player42 — Sign Out" and `evidence/p14-settings-signed-out-*.png` the empty account row.
- Not covered here: the comparison against live retroachievements.org for a real account. See maintainer step 3.

### RetroAchievements — Hardcore

- Check: `ConsoleExtrasPanelTests.hardcoreTurnsOffStates` (logic passes; the `seen("Hardcore turns off Continue From")` line needs Vision), `ExtrasTests.retroArchsLogNamesTheGameAndHardcore`, `ExtrasIntegrationTests.hardcoreIsActiveAndForbidsStatesAndRewind` (rig-gated).
- Result: with `hardcore` on, `content.statesAllowed` is false, the Play button reads "Play" not "Resume", and pressing Play with a state chosen still launches with `request.hardcore == true`, `slot == nil`, `resume == false`. `StateButton`s in the Continue From strip render `disabled:` (P16's `route` merge kept this: `hasAutoState && route == .retroArch && statesAllowed`). The caption under the Hardcore row reads "Hardcore turns off Continue From while you play." — visible in `evidence/p14-panel-hardcore-*.png`.
- RetroArch reporting hardcore active: the rig test signs rcheevos in over loopback HTTP, waits for `cheevos_hardcore` to read `on`, asserts `rewind == off`, that a state *save* still works but `loadState` is refused, that the token reaches RetroArch's config and is scrubbed from `cartouche.cfg` once read, and that no password ever went to the server. Rig-gated — maintainer step 2. `retroArchsLogNamesTheGameAndHardcore` (passes) checks the log parsing the panel relies on.

### Screen translation — Not configured

- Check: `ConsoleExtrasTests.translationNeedsAServiceAndTheGamesChoice` (passes), `ConsoleExtrasPanelTests.translationNotConfigured` (logic passes; the `seen(…)` lines need Vision).
- Result: `ConsoleOptionsSections.needsService == "Needs a translation service, set in Settings"`, the exact spec wording. With no service configured, `setTranslate(true, for:)` leaves `translates(game) == false`, and `extras.apply(to:&request)` produces `request.translation == nil` — the toggle does nothing else. `evidence/p14-more-options-*.png` shows the off toggle and the caption.
- With a service set, the address is stored (Settings "Set Up…" sheet; `p14-settings-signed-in-*.png` reads "Used by Translate the screen: http://192.168.1.5:4404/") and RetroArch gets its AI-service URL. Per-game toggles persist in `extras.json`.

### Saves in iCloud Drive — Two Macs

- Check: `CloudSavesTests.aStateSavedOnOneMacIsListedOnTheOther` and `iCloudDriveOffIsSaid` (both pass), `ExtrasIntegrationTests.aStateSavedOnMacAIsContinuedOnMacB` (rig-gated).
- Result: `turnOn()` replaces Cartouche's local `saves`/`states` folders with symbolic links into `iCloud Drive/Cartouche/Saves` and `…/States`. The unit test gives a second `RetroArchPaths` ("Mac B") the same drive folder: a state written on "Mac A" is listed by Mac B's `SaveStates.list`. `iCloudDriveOffIsSaid` covers the option off / iCloud absent wording (`p14-settings-signed-*.png` shows the toggle and the "iCloud Drive's Cartouche folder" caption).
- The rig test runs real RetroArch on "Mac A", saves slot 2 + auto state to the shared folder, then asserts "Mac B" lists both — a real two-root proof of the symlink layout. Rig-gated; real iCloud sync and the second physical Mac are maintainer step 4.

### Coach mode — Reads, never cheats

- Check: `CoachTests` (3 tests, all pass), `ConsoleExtrasTests.coachModeIsOffUntilTurnedOn` (passes), `ConsoleExtrasPanelTests.coachRelay` (passes), `ExtrasIntegrationTests.theCoachReadsInHardcoreAndIsRefusedInput` (rig-gated).
- Result: coach is off per game by default (`!extras.coaches(game)`; `coachModeIsOffUntilTurnedOn`) and the sheet marks it "Experimental" (`evidence/p14-more-options-*.png`: "Coach — Experimental / Coach mode — … never presses a button in Hardcore mode."). `namedValuesComeFromTheRichPresenceScript` parses `Display:\nFrame @Frames(0xX0000)` into named values from the game's RetroAchievements Rich Presence definition — that is where the names come from. Reads go through `READ_CORE_MEMORY` on Cartouche's MCP relay only (`inHardcoreReadingWorksAndPressingIsRefused`); `coach_press` with Hardcore active returns `isError` and text containing "Hardcore mode" **before** anything reaches RetroArch (both the unit and app tests assert the error). Outside Hardcore the same press reaches RetroArch.
- The rig test additionally proves frames are actually read from a running core (frame count grows between two reads) and the press reaches a real session outside Hardcore. Rig-gated — maintainer step 5.

## Maintainer steps (real RetroArch, real services, real second Mac)

1. `make retroarch-rig retroarch-testcore`, then `CARTOUCHE_RETROARCH=<rig> CARTOUCHE_TEST_CORE=<core> swift test --package-path retroarch`. Expect `hostAndJoinWithinTenSeconds` to print `evidence: … "You have joined as player 2" … took <10s`, `hardcoreIsActiveAndForbidsStatesAndRewind` to print `evidence: GET_OPTION cheevos_hardcore=on …`, `theCoachReadsInHardcoreAndIsRefusedInput` the growing frame reads, and `aStateSavedOnMacAIsContinuedOnMacB` Mac B's state list.
2. Two-Mac netplay: sign into the same nickname on two Macs on one network, open the same game, A presses Host, B opens Join — B should see A's room under "On this network" (Bonjour `_ra_netplay._tcp`) or via the lobby when announced, join, and both control their own player. This is also the Local Network permission prompt; PRIVACY.md covers it.
3. Live RetroAchievements: sign in in Settings > Consoles with a real account, open a played game, and compare "N of M" with the game's page on retroachievements.org for that account.
4. Two-Mac iCloud: turn on "Save states to iCloud Drive" on both Macs, save a state on A, let iCloud sync, start Cartouche on B — Continue From shows the state.
5. A real translation service (e.g. RetroArch's own `translate` endpoint or a local server): set it in Settings > Consoles, turn on "Translate the screen" for a game, and check RetroArch translates the frame on request.
6. A real MCP client: turn on Coach mode for a game (off by default), connect to Cartouche's relay, read a named value, and ask for a press — allowed outside Hardcore, refused with "Hardcore mode" inside it.
