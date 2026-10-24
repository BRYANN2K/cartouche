# Protected Steam owned-library export

Status: implemented in 451e393, merged to main in de0e6ec. Real Steam verification remains pending. Maintainer decision: 2026-10-20. ADRs: 0021 and 0022. Merged in 9214df4 (`fix/steam-compat-tools`) and cb248b2 (`fix/steam-export-token`), pending a real Steam check after Repair: the page script fetches the token at run time from `/cartouche/steam-export-token` (no-store, backoff 15 s→300 s) instead of carrying it in the injected source, and Cartouche Wine builds register as Steam compatibility tools.

## Why

Local Steam files do not prove complete ownership. The existing app-side importer needs the authenticated client’s owned-games export.

## What changes

Add a dylib WebUI route, protected by a per-launch random token known only to Cartouche’s injected page script. Validate the submitted SteamExport v1 data and atomically write steam-library.json. Keep the last account-matched export while Steam is closed, labelled cached/stale. Use appmanifests for installed status and localconfig.vdf for play data only.

## Rejected approaches

Loopback HTTP, a public Steam profile, and a user Web API key. No new network service or general file-write endpoint is introduced.

## Scope

The game-library specification defines acceptance. This change replaces its earlier exclusion of the writer from v0.1.0. Implementation and automated checks are merged. Real Steam verification, including account switching and freshness, remains pending.
