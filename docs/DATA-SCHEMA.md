# Cartouche data schemas and data licenses

The shape of the compatibility file, the MacGamingDB cache on the Mac, the other stores the merged phases keep, and the license of each data source. Read by contributors who change the builder or the app's code that touches them, and by anyone checking attribution. The compatibility schema file is `docs/schema/compat.schema.json`. If this page and the schema file differ, the schema file wins.

## Overview

| Data | Where it lives | Who writes it | Who reads it |
|---|---|---|---|
| `compat.json.gz` | Release asset `compat-data` on GitHub | `.github/workflows/compat-data.yml`, every night at 03:17 UTC, with `tools/compat` | The app, at most once a day |
| Cached copy of `compat.json.gz` | `~/Library/Application Support/Cartouche/compatibility/compat.json.gz` | The app | The app |
| `fetch-state.json` | Same folder | The app | The app. It holds the time of the last contact |
| MacGamingDB cache | `~/Library/Application Support/Cartouche/compatibility/macgamingdb/<appid>.json` | The app | The app |

The file is gzip JSON, under 25 MB. Every record is keyed by Steam App ID, and every value sits under the source it came from. The build fails if the file does not validate against the schema or is over the size limit.

The schema uses only a small set of JSON Schema keywords, because the builder and the app each carry their own small validator. The list is in the schema's `$comment`.

## compat.json

### Top level

All fields are required. No other field is allowed.

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | `1` | The only value today |
| `generated` | date-time, UTC | When the builder wrote the file |
| `sources` | object | One block per source, see below. Exactly `applegamingwiki`, `protondb`, `areweanticheatyet` |
| `gpu_strength` | object | Rough relative GPU strength per chip, M1 = 1. Keys look like `M4 Pro`. Values are numbers above 0. At least one entry |
| `records` | object | Keys are Steam App IDs (digits, no leading zero, up to 10 digits). Values are records |

`gpu_strength` is a rough guess kept in `tools/compat/gpu_strength.json`. It can change without an app update. The app uses it with the MacGamingDB reports it reads live, only to find comparable Macs.

### Source block

One per source in `sources`. All fields are required, except `export`.

| Field | Meaning |
|---|---|
| `name`, `credit`, `url` | Name, how the app names it next to its data (with the license), and its web address (https) |
| `license`, `license_url` | License name and the address of its text (https) |
| `attribution` | The sentence the app shows |
| `fetched` | Date (UTC) the source last answered. Older than `generated` when the source was down |
| `status` | `fresh`, or `stale` when the source failed in this build and its records are the previous ones |
| `export` | ProtonDB only: the monthly export the records come from |

### Record

| Field | Meaning |
|---|---|
| `name` | The game's name. Required |
| `applegamingwiki` | Optional block |
| `protondb` | Optional block |
| `areweanticheatyet` | Optional block |

A record has `name` and at least one source block.

### applegamingwiki block

| Field | Meaning |
|---|---|
| `fetched` | Date |
| `page` | Wiki page title |
| `revision` | Revision number, 1 or more |
| `ratings` | One rating per method: `native`, `rosetta2`, `crossover`, `wine`, `parallels`. All five are required |

A rating is one of `perfect`, `playable`, `runs`, `menu` (reaches the menu only), `unplayable`, `unknown`, `na` (the method does not apply).

### protondb block

Linux reports from the ProtonDB export. The counts cover the year before the export's newest report.

| Field | Meaning |
|---|---|
| `fetched` | Date of the export |
| `since` | Reports older than this date are not counted |
| `reports` | Number of reports, 1 or more |
| `works` | Count of reports whose verdict is yes |
| `online_tried` | Count of reports that tried online multiplayer |
| `online_played` | Of those, the count that played online |
| `verdict` | `runs` (at least 3 in 4 reports say it runs on Linux), `doesnt_run` (at most 1 in 4), or `mixed` |

All counts are integers of 0 or more.

### areweanticheatyet block

| Field | Meaning |
|---|---|
| `fetched` | Date |
| `status` | `Supported`, `Running`, `Planned`, `Broken` or `Denied`. These are Linux statuses |
| `anticheats` | Names of the anti-cheat programs. At least one |
| `native` | The `native` flag of the AreWeAntiCheatYet entry, as a boolean |
| `changed` | Date the status last changed |

### Which games are in the file

The file covers games people play: Steam's most played games, every game in AppleGamingWiki or AreWeAntiCheatYet, and every game with at least 10 ProtonDB reports in the last year. If Steam's list cannot be read, the builder keeps the games of the previous file.

### When a source is down

The builder keeps that source's records from the previous file, with their old `fetched` date, marks the source `stale`, and still publishes. A source that changes format fails the job and the previous file stays live.

### How the app uses it

- It validates the download against the same schema. A file that fails is discarded and the previous copy stays in use.
- It discards a download whose `generated` is older than the copy in use.
- It shows the age of the data when it is older than 3 days.
- Anti-cheat data is shown as Linux data only, with counts. The app never states a macOS outcome (ADR 0009).

## MacGamingDB cache

MacGamingDB is not in `compat.json`. The app reads `https://macgamingdb.app/api/rest/games/<appid>` live, only when a game's details or estimate need it, and only when Settings > Privacy > Fetch Mac reports from MacGamingDB is on.

One file per game, `<appid>.json`, written atomically:

| Field | Meaning |
|---|---|
| `fetched` | ISO 8601 time of the answer |
| `entry.rating` | MacGamingDB's aggregate: `unplayable`, `barely_playable`, `playable`, `good`, `very_good`, `excellent`, or absent |
| `entry.reviewCount` | Number of reviews MacGamingDB reports |
| `entry.topLayer` | Most reported translation layer: `d3dmetal`, `dxmt`, `dxvk`, or absent. Ties go to D3DMetal, then DXMT, then DXVK |
| `entry.reports` | Raw report rows, below |

A report row keeps only what the estimate needs:

| Field | Meaning |
|---|---|
| `chip` | `M1` to `M9` or `A10` to `A99`, with ` Pro`, ` Max` or ` Ultra` |
| `method` | `native`, `wine`, `parallels` or `other` |
| `layer` | `d3dmetal`, `dxmt`, `dxvk`, or absent |
| `rating` | 0 to 5, in the order of the rating names above |
| `fps` | Whole number 1 to 1000, or absent |
| `settings` | `low`, `medium`, `high`, `ultra`, or absent |
| `date` | `YYYY-MM-DD` |

Rules:

- A report with a value Cartouche does not know is left out.
- The cache is valid for 24 hours. After that the app asks again. If MacGamingDB cannot answer, or its answer cannot be read, the last good copy stays in use.
- A 404 is cached as an empty entry.
- The cache stays on the Mac. It is never uploaded and never copied into `compat.json`.

### The per-Mac estimate

- It uses reports with the same play method on Macs whose GPU strength is within 1/1.4 to 1.4 times this Mac's, from the `gpu_strength` table.
- With fewer than 3 matching reports, it uses the 5 closest.
- It returns a rating, average FPS and typical settings, and says how many reports it used.
- With no reports for the play method, the panel says "No reports yet for this version" and shows no number.

## Data licenses

| Source | License | In `compat.json` | Obligations |
|---|---|---|---|
| AppleGamingWiki | CC BY-NC-SA 3.0 | Ratings per method | Credit the source. Non-commercial use. Share the ratings under the same license. The file's attribution text says so |
| ProtonDB | ODbL 1.0 (monthly export) | Report counts and verdict | Credit the source. The counts in the file are shared under the same license |
| AreWeAntiCheatYet | MIT | Anti-cheat status | Keep the copyright notice: "Copyright (c) 2021 Starz0r, Curve. MIT License." |
| MacGamingDB | No data license published | Never | Read live by the app and kept on the user's Mac. Cartouche does not redistribute it |

- Every screen that shows community data names its sources. The Details sheet of a game names MacGamingDB, AppleGamingWiki (CC BY-NC-SA 3.0), ProtonDB (ODbL) and AreWeAntiCheatYet. The license list comes from the data file, plus a fixed entry for MacGamingDB.
- `tools/compat/check_published.py` fails if the published file names MacGamingDB anywhere.
- Code licenses for the tools that read these sources are in `THIRD-PARTY-LICENSES` and `NOTICE`. They are separate from the data licenses above.

## Other stores

These are merged. Their shapes come from the code named beside them; none of them is a contract with another program.

### FPS store (P8)

`~/Library/Application Support/Cartouche/performance/sessions.sqlite`, written by `PerformanceStore` in `app/Sources/NotProtonApp/Performance/PerformanceStore.swift`. `PRAGMA user_version = 1`.

- `sessions`: one row per play session. `folder` (the launch folder it came from, unique), `app_id`, `runner`, `translation`, `backend`, `runner_name`, `settings` (JSON object of the game's Cartouche variables), `started`, `ended` (Unix time), `measurement` (`on` or `refused`), `measured_seconds`, `frames`, `average`, `low1`, `histogram` (`fps:count` pairs), `width`, `height`.
- `samples`: one row per second of a session, `session` references `sessions.id` with cascade delete. `time`, `frames`, `frontmost`, `counted`.
- The run script leaves one folder per launch under `performance/incoming/` (`session` plus `samples-*` files); the store folds finished folders into the SQLite file and deletes them.

### Library store (P5)

`library.json` in the app data folder, written by `LibraryStore` (`app/Sources/NotProtonApp/Library/LibraryStore.swift`).

- `favorites`, `hidden`: game ID lists.
- `covers`: game ID to a file name under `covers/` (a copy of the image the user dropped).
- `setups`: game ID to a `GameSetupChoice` (`runnerID`, `graphics`, `translation`, `metalHUD`, `version`, `environment`; every field optional).

`steam-library.json` in the app data folder is the cached copy of the export the Steam side is meant to write (version 1). The Steam side that writes it is not done (P5 task 1.1); the app reads Steam's own files meanwhile.

### Store records (P10)

`stores/` in the app data folder, from `StoreRecords.swift`. No file here holds a token.

- `stores/<store>/library.json`: the account's games as last listed, for offline browsing.
- `stores/<store>/games/<id>.json`: one installed game (store, ID, title, install path, `saveStamps`, `installedAt`, `imported`).
- `stores/<store>/client` and `stores/<store>/home`: the client's config folder and private HOME. Token files appear in them only while the client runs.
- `stores/<store>/<slug>/pfx`: the game's Wine prefix.

### Console extras (P14)

`retroarch/extras.json` in the app data folder, from `ConsoleExtras.swift` (`ExtrasSettings`). Every key may be missing, so an older file still reads.

- `username`, `translationService`, `netplayNickname`, `cloudSaves`, `translate`, `coach`, `gameIDs`, `progress`. No secrets; the RetroAchievements token is in the Keychain.

## Not decided

- Nothing at the moment.
