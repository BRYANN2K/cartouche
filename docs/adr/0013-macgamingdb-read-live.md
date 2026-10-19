# 0013. MacGamingDB is read live by the app and never redistributed

One accepted decision for Cartouche. Read by contributors who need to know why. It supersedes the parts of ADR 0005 that put MacGamingDB data in the nightly file, and the MIT license given for MacGamingDB in earlier documents.

## Status

Accepted, 2026-10-19. Supersedes ADR 0005 in part: the nightly file no longer carries MacGamingDB data. The rest of ADR 0005 stands.

## Context

ADR 0005 listed MacGamingDB as a source of the nightly file and kept raw report rows in it. Earlier documents called MacGamingDB MIT licensed. MacGamingDB publishes no license for its data. Cartouche may read the reports. It may not redistribute them.

## Decision

- The nightly file carries data from AppleGamingWiki, ProtonDB and AreWeAntiCheatYet only. A check fails the publish if the file names MacGamingDB.
- The app asks `https://macgamingdb.app/api/rest/games/<appid>` when a game's details or estimate are needed. It caches each game's answer on the Mac, asks again at most once a day per game, and keeps the last good copy for offline use. At most two requests run at once.
- The raw report rows stay in the Mac's cache, so the per-Mac estimate still runs on the Mac.
- Settings > Privacy has "Fetch Mac reports from MacGamingDB", on by default. Off, no request goes to macgamingdb.app and no estimate is shown.
- `docs/PRIVACY.md` says that MacGamingDB sees which games the user opens.

## Alternatives rejected

- Redistribute MacGamingDB data in the nightly file. Rejected: no data license.
- Prefetch MacGamingDB for the whole library. Rejected: it would send every owned game to MacGamingDB and load its API.
- Precomputed estimates in the file. Rejected: they cannot follow a different Mac, and they would still redistribute the data.

## Consequences

- A game never opened has no Mac estimate until the app can reach MacGamingDB.
- MacGamingDB sees the Steam App IDs of games the user opens, and the user's IP address.
- If MacGamingDB publishes a data license, a new ADR can move its data into the file.
- ADR 0005 stays as written. Read it with this ADR.
