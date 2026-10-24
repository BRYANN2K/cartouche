# Proposal

## Why

Players decide what to install and how to set it up from community reports. MacGamingDB has Mac reports per chip and backend, AppleGamingWiki has ratings per method, ProtonDB and AreWeAntiCheatYet have Linux anti-cheat data. The ProtonDB export alone is 70 MB, so each Mac cannot fetch everything itself, and there is no server. MacGamingDB publishes no data license, so Cartouche may read it but must not redistribute it.

## What Changes

- A nightly GitHub Actions job builds one compatibility file from AppleGamingWiki, ProtonDB (monthly ODbL export) and AreWeAntiCheatYet, and publishes it as a release asset. The file carries no MacGamingDB data.
- The app downloads that file once a day, keeps the last good copy, and works offline from it.
- The app reads MacGamingDB reports itself, from `/api/rest/games/{appid}`, only when a game's details or estimate are needed. Each game's answer is cached on the Mac, refreshed at most once a day, and the last good copy is kept for offline use.
- Settings > Privacy gets a toggle "Fetch Mac reports from MacGamingDB", on by default. Off, the app sends nothing to MacGamingDB, shows AppleGamingWiki only and no estimate.
- The per-Mac estimate: rating, average FPS and typical settings from the cached MacGamingDB reports on comparable Macs.
- Anti-cheat information is shown as Linux data, quoted from ProtonDB and AreWeAntiCheatYet, never as a Mac verdict.
- Source attribution and licenses (CC BY-NC-SA 3.0, ODbL, MIT) shown in the app, and MacGamingDB named as a live source.
- Non-goals: user reports to MacGamingDB (P8 opt-in), store data (P10), prefetching MacGamingDB for the whole library.
- Depends on P0.

## Capabilities

### New Capabilities
- `compatibility-data`: building, publishing, fetching and presenting community compatibility data, reading MacGamingDB live, and the per-Mac estimate.

### Modified Capabilities
- None.

## Impact

New `.github/workflows/compat-data.yml` and a small builder (Python script in `tools/`), a JSON schema in `docs/schema/`, a client cache and a MacGamingDB client in the app, a toggle in Settings > Privacy. DATA-SCHEMA and PRIVACY docs. PRIVACY must say that MacGamingDB sees which games the user opens, with no account and no Mac identifier sent beyond the HTTP request itself.
