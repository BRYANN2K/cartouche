# compatibility-data Specification

## Purpose
How Cartouche builds and publishes the nightly compatibility file (AppleGamingWiki, ProtonDB, AreWeAntiCheatYet), reads MacGamingDB live per game without redistributing it, and presents ratings, Linux anti-cheat data and the per-Mac estimate.

## Requirements

### Requirement: Nightly data file
CI SHALL publish, every night, one compatibility file that validates against the published JSON schema, with each record keyed by Steam App ID and each value attributed to its source. The file SHALL carry data from AppleGamingWiki, ProtonDB and AreWeAntiCheatYet only, and no MacGamingDB data.

#### Scenario: Nightly build succeeds
- **WHEN** the nightly workflow runs
- **THEN** it publishes `compat.json` (gzip) under 25 MB, valid against `docs/schema/compat.schema.json`, with a `generated` date of that night

#### Scenario: A source is down
- **WHEN** one source fails to answer during the build
- **THEN** the workflow keeps that source's records from the previous file, marks them with their old date, and still publishes

#### Scenario: Known values are right
- **WHEN** the file is checked against fixtures recorded on 2026-10-18
- **THEN** Apex Legends (1172470) has ProtonDB "doesn't run" with Easy Anti-Cheat and Hyperion

#### Scenario: No MacGamingDB data is published
- **WHEN** the published `compat.json` is scanned
- **THEN** it contains no MacGamingDB field, source entry or value, and the check fails the build if one appears

### Requirement: MacGamingDB read live
The app SHALL read MacGamingDB reports from `/api/rest/games/{appid}` only when a game's details or estimate are needed, SHALL cache each game's answer on the Mac, SHALL ask again at most once a day per game, SHALL keep the last good copy for offline use, and SHALL send nothing to MacGamingDB when the user turns off "Fetch Mac reports from MacGamingDB" in Settings > Privacy.

#### Scenario: First open of a game
- **WHEN** the Elden Ring panel opens with no cached MacGamingDB data and the network is up
- **THEN** the app makes one request to MacGamingDB for 1245620, caches it, shows "Very Good" with D3DMetal as the most reported layer, and a second open the same day makes no request

#### Scenario: Mac reports turned off
- **WHEN** the "Fetch Mac reports from MacGamingDB" toggle is off
- **THEN** no request goes to macgamingdb.app and the estimate area says Mac reports are turned off

### Requirement: Offline-first client
The app SHALL fetch the file at most once a day, SHALL keep the last valid copy, and SHALL show its age when it is older than 3 days.

#### Scenario: Offline launch
- **WHEN** the Mac is offline and a cached file exists
- **THEN** the library shows compatibility data from the cache and the game panel reads "Offline. Compatibility data from N days ago." when N > 3

#### Scenario: Corrupt download
- **WHEN** the downloaded file fails schema validation
- **THEN** it is discarded and the previous copy stays in use

### Requirement: Per-Mac estimate
For a game, the app SHALL estimate rating, average FPS and typical settings from the cached live MacGamingDB reports with the same play method on Macs whose GPU strength is within 1/1.4× to 1.4× of this Mac, falling back to the five closest reports when fewer than three match, and SHALL say how many reports it used.

#### Scenario: Estimate for an M4
- **WHEN** the estimate for Elden Ring is computed for an M4 from the 2026-10-18 fixture
- **THEN** it returns rating Good, about 52 fps, settings High, from 13 reports including 7 on M4

#### Scenario: No reports
- **WHEN** a game has no reports for its play method
- **THEN** the panel says "No reports yet for this version" and shows no number

### Requirement: Anti-cheat as Linux data
Anti-cheat information SHALL be presented as what ProtonDB and AreWeAntiCheatYet report for Linux, with counts, and SHALL NOT claim whether online play works on macOS.

#### Scenario: Wording
- **WHEN** the anti-cheat strings of the app are reviewed
- **THEN** every one is phrased about Linux (for example "Online works on Linux, 26 of 26 reports") and none states a macOS outcome

### Requirement: Attribution
Every screen that shows community data SHALL name its sources, and the app SHALL list their licenses.

#### Scenario: Sources are visible
- **WHEN** the Details sheet of any game is opened
- **THEN** it names MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL) and AreWeAntiCheatYet
