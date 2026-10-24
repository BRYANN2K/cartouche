# Evidence: p4-compatibility-data

Branch `phase/p4-compatibility-data`, merged with main 3febbf1 (P1, P17). Machine: Apple M4, Xcode 27.0, Swift 6.4, Python 3.14.

MacGamingDB publishes no data license, so the nightly file carries AppleGamingWiki, ProtonDB and AreWeAntiCheatYet only, and the app reads MacGamingDB live, per game (spec commit 2560331).

## Tests

| Suite | Before (main a81a5b1) | After merge with main 3febbf1 |
|---|---|---|
| `make -s app-tests` | 554 tests, 34 fail (43 issues) | 681 tests, the same 34 fail (43 issues). 641 come from main, 40 are this phase's |
| `make -s compat-data-tests` (new) | not present | 47 tests, all pass |
| Hermetic C and shell suites from `app.yml` (19), plus `runcheck`, `scriptcheck` | 21 pass | 21 pass (`runcheck` and `scriptcheck` skip: shellcheck is not installed here) |
| `make -s -o app-payload app && make -s l10ncheck` | 433 strings, all translated | 543 strings, all translated except "The trial version is not supported." in zh-Hans, as on main |
| `openspec validate --all --strict` | | 19 passed, 0 failed |

- The 34 failing Swift tests need the staged payload ("This build carries no components at all"). The sorted list of failing test names is identical to the baseline.
- New Swift tests: `CompatibilityClientTests.swift` ("Compatibility data client", "Compatibility schema"), `CompatEstimateTests.swift` ("Per-Mac estimate"), `CompatibilityWordingTests.swift` ("Anti-cheat wording and attribution"), `MacGamingDBTests.swift` ("MacGamingDB read live").
- No existing test was changed. Builder tests written earlier in this phase for the builder's MacGamingDB source were removed with that source; their parsing checks moved to `MacGamingDBTests.unknownValues` and `parsesTheAnswer`.
- The 36 strings this phase adds are translated into zh-Hans and it.

## Fixtures

- Recorded on 2026-10-19 with `tools/compat/record_fixtures.py` into `tools/compat/fixtures/2026-10-19/`, for Elden Ring, Apex Legends, Counter-Strike 2 and Disco Elysium. What was cut and the license of each part: `tools/compat/fixtures/README.md`.
- The spec says "recorded on 2026-10-18". The MacGamingDB rows for Elden Ring are the same 25 rows, in the same order, as the 2026-10-18 pull in `mockup/launcher.html` (one-off comparison: `mockup rows 25 fixture rows 25 identical in order: True`). The game's newest report is from 2026-10-05.
- Only the Elden Ring MacGamingDB answer is kept, with authors, notes and screenshots removed. The app's tests read it. The builder does not.
- `tools/compat/fixtures/compat-2026-10-19.json.gz` is the builder's output for these fixtures, read by the Swift tests. `AppFixtureTests.test_the_app_tests_read_the_current_fixture_build` fails if it drifts.

## Scenarios

### Nightly data file / Nightly build succeeds
- Check: tests `FixtureBuildTests.test_file_matches_the_schema`, `test_generated_is_the_build_night`, `test_records_are_keyed_by_app_id`, `test_every_value_sits_under_a_named_source`, `FailureTests.test_encoded_file_is_gzip_of_the_document`, `test_a_file_over_the_limit_is_refused`, `test_a_schema_break_stops_the_build`, `CheckPublishedTests` (5 tests).
- Check: command `build_compat.py --fixtures tools/compat/fixtures/2026-10-19 --now 2026-10-19T03:17:00Z --out fixture.json.gz && check_published.py fixture.json.gz --night 2026-10-19`
- Result: pass. `fixture.json.gz: 1074 bytes, 4 records, generated 2026-10-19T03:17:00Z, schema valid`. With `--night 2026-10-20` the check exits 1.
- Check: live runs on this Mac, with the workflow's commands (`build_compat.py --out compat.json.gz --cache DIR`, then `check_published.py compat.json.gz --night "$(date -u +%F)"`). The ProtonDB export (71.5 MB) was downloaded once and its summary seeded in the cache.
- Result: pass. Last run without MacGamingDB: `2215 records, generated 2026-10-19T00:47:44Z, 61544 bytes gzip (538242 raw), 7 requests`, then `schema valid`. 61.5 KB is far under 25 MB. Records by source: AppleGamingWiki 619, ProtonDB 1809, AreWeAntiCheatYet 677.
- Found by the live runs and fixed: AppleGamingWiki's `{{Rating}}` template also has `menu`, now in the schema; two wiki pages giving one App ID (Counter-Strike 2 and Counter-Strike: Global Offensive, both 730) resolve to the most recently edited page; two builds sharing a cache folder collided on a temporary file name.
- Politeness: the requests carry `Cartouche-compat-builder/1 (Cartouche game launcher; nightly, cached…)` and are spaced one second per host, with backoff. Earlier full runs, made while MacGamingDB was still in the builder, sent about 800 requests to MacGamingDB. For 12 minutes two of those runs overlapped by mistake. The builder's MacGamingDB cache was then pruned, and the downloaded MacGamingDB answers deleted from this Mac.
- Not done: a run of `.github/workflows/compat-data.yml` on GitHub. It needs a push and a manual dispatch. The workflow runs the same two scripts and adds the jsonschema 4.23.0 reference validator, which is not installed here.

### Nightly data file / A source is down
- Check: tests `SourceDownTests.test_each_source_down_keeps_its_previous_records_with_their_old_date` (each of the three sources), `test_kept_wiki_records_carry_the_old_date`, `test_the_wiki_failing_after_its_listing_keeps_all_its_records`, `test_the_command_still_publishes`, `test_steam_down_keeps_the_previous_games`, `test_without_a_previous_file_a_down_source_stops_the_build`.
- Check: command: build the fixtures for the night of 2026-10-18, then `build_compat.py --fixtures … --down applegamingwiki --previous prev.json.gz --now 2026-10-19T03:17:00Z --out down.json.gz`, then `check_published.py down.json.gz --night 2026-10-19`.
- Result: pass. `Keeping 4 records from 2026-10-18`, `applegamingwiki: stale, 2026-10-18`, the other two `fresh, 2026-10-19`, and the check prints `schema valid, stale: applegamingwiki`.
- A source answering in a format the builder cannot read stops the build instead, so the previous file stays live (`FailureTests.test_unknown_format_stops_the_build`).

### Nightly data file / Known values are right
- Check: test `FixtureBuildTests.test_apex_does_not_run_on_linux_with_eac_and_hyperion`; Swift `CompatibilityClientTests.fixtureReads`.
- Result: pass. Apex Legends (1172470): `protondb.verdict` = `doesnt_run` (0 of 149 reports run, since 2025-10-01), `areweanticheatyet.anticheats` = `["Easy Anti-Cheat", "Hyperion"]`, status `Denied`.
- ProtonDB's export has no tier. `doesnt_run` means at most 1 in 4 reports from the last year say the game runs (schema, `protondb.verdict`).

### Nightly data file / No MacGamingDB data is published
- Check: tests `FixtureBuildTests.test_no_macgamingdb_field_or_value_is_published` (the raw and the gzip output contain no "macgamingdb" in any case, and the build makes no request to macgamingdb.app), `CheckPublishedTests.test_a_file_carrying_macgamingdb_fails`, `SchemaTests.test_each_break_is_caught` ("a MacGamingDB source", "a MacGamingDB block"); Swift `CompatibilityClientTests.fixtureReads`, `CompatSchemaTests.breaksAreCaught` (a `macgamingdb` source is refused).
- Check: command `grep -ic macgamingdb compat.json` on the live output.
- Result: pass. `0`. `check_published.py`, which the workflow runs before publishing, exits 1 when the file names MacGamingDB anywhere.

### MacGamingDB read live / First open of a game
- Check: Swift tests `MacGamingDBTests.firstAndSecondOpen`, `parsesTheAnswer`, `refreshAndOffline`, `nothingCached`, `politeness`, `userAgent`.
- Result: pass. Opening Elden Ring with no cache makes exactly one request, `https://macgamingdb.app/api/rest/games/1245620` (recorded answer), writes `macgamingdb/1245620.json`, and the panel's MacGamingDB lines read `Very Good`, `Most reported layer: D3DMetal` (21 of 25 reports). Opening again 20 hours later, and from a new model 23 hours later, makes no request. After 25 hours it asks again; offline, a damaged answer or HTTP 503 keep the last good copy. Seven lookups of five games run at most two requests at a time, and the game asked three times at once is fetched once. The User-Agent is `Cartouche/<version> (+https://cartouche.bryann2k.dev)`.
- Not yet on screen: the panel is P5. `CompatibilityModel.openGame(appID:)` is what it calls when a game opens. The library never prefetches.

### MacGamingDB read live / Mac reports turned off
- Check: Swift tests `MacGamingDBTests.toggleOff`, `toggleOffHidesCache`.
- Result: pass. "Fetch Mac reports from MacGamingDB" (`PrivacyChoices.fetchMacReports`) is on by default and the choice is kept in user defaults. Off, `openGame` sends no request, the estimate area reads `Mac reports are turned off in Settings > Privacy`, no MacGamingDB line is shown even for a game already cached, and the AppleGamingWiki ratings stay.
- The toggle and its explanation are in `PrivacySettingsView`, above the permission list. The Settings window that hosts it comes with P5; `PrivacySettingsTests.renders` still renders the view.

### Offline-first client / Offline launch
- Check: Swift tests `CompatibilityClientTests.offlineLaunch`, `ageThreshold`, `offlineWithoutCache`, `onceADay`.
- Result: pass. With a cached file and the network failing, the model keeps the cached data (`record(appID: 1245620)?.name == "Elden Ring"`), `isOffline` is true, and `ageNotice` is `Offline. Compatibility data from 5 days ago.` At 3 days and 1 hour there is no notice; at 4 days it reads `… from 4 days ago.`. After a successful contact, a refresh 23 hours later does not ask the server and one 25 hours later does. A failed connection does not count as the day's fetch.

### Offline-first client / Corrupt download
- Check: Swift test `CompatibilityClientTests.corruptDownload` (truncated gzip, damaged gzip, not JSON, a schema break, a valid but older file), `damagedCache`, `CompatSchemaTests.breaksAreCaught` (12 cases), `gzipChecksum`.
- Result: pass. Each download is rejected, the cache file is byte-for-byte unchanged, and the previous copy stays in use. The app checks the file against a bundled copy of `docs/schema/compat.schema.json`, kept equal by `bundledSchemaIsTheDocumentedOne`.

### Per-Mac estimate / Estimate for an M4
- Check: Swift tests `CompatEstimateTests.eldenRingOnM4`, `eldenRingPanelLines`, `comparableWindow`, `fallbackToClosest`, `settingsTie`. The reports are the recorded MacGamingDB answer, read as the live cache stores it (`MacGamingDBEntry.parse`).
- Result: pass. Elden Ring, Wine method, M4: rating Good, 52 fps (mean of 9 values, 40 to 60), settings High, 13 reports of which 7 on M4. Panel lines `Good`, `About 52 fps`, `High settings`, `Reports used: 13, including 7 on M4`. The window is 1/1.4 to 1.4: 1.39 and 1/1.39 are in, 1.41 and 1/1.41 are out.

### Per-Mac estimate / No reports
- Check: Swift test `CompatEstimateTests.noReports`.
- Result: pass. Elden Ring with the native method, Apex Legends (MacGamingDB knows no report) and a game never fetched all give `["No reports yet for this version"]`, and no line contains a digit.

### Anti-cheat as Linux data / Wording
- Check: Swift tests `CompatibilityWordingTests.everyLineIsAboutLinux` (105 combinations of ProtonDB cases, statuses and anti-cheat lists), `sourceStringsNameLinux` (the 13 `String(localized:)` literals in `AntiCheatSummary.swift`), `onlineCounts`, `apexLegends`, `eldenRing`, `noAntiCheat`.
- Result: pass. Every English line contains "Linux" and none contains "mac" in any case. 26 of 26 online reports read `Online works on Linux, 26 of 26 reports`. Apex Legends reads `Doesn’t run on Linux`, `149 of 149 recent ProtonDB reports say it doesn’t run on Linux.`, `No recent ProtonDB report tried online play on Linux.`, `AreWeAntiCheatYet lists Easy Anti-Cheat and Hyperion as denied on Linux by the developer.` The zh-Hans and it translations name Linux in every one of those strings too.

### Attribution / Sources are visible
- Check: Swift tests `CompatibilityWordingTests.detailsNameTheSources` (five games), `licenses`.
- Result: pass at the data layer. `CompatibilityPanel.credits` is `MacGamingDB`, `AppleGamingWiki (CC BY-NC-SA 3.0)`, `ProtonDB (ODbL)`, `AreWeAntiCheatYet (MIT)` for every game, and `sourcesLine` reads `Sources: MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL), and AreWeAntiCheatYet (MIT)`. MacGamingDB's credit is in the app, since the file no longer carries it; the other three come from the file's `sources`. `CompatibilityCredits.licenses` lists each source's license, URL and attribution, including "No data license published" and the live-read note for MacGamingDB.
- Not yet on screen: the Details sheet is P5. It must show `CompatibilityPanel.credits`.
