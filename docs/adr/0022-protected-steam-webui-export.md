# 0022. Steam library export through a protected WebUI route

## Status

Accepted, 2026-10-20. Extends ADR 0021 with the export transport. Implementation is in progress on `phase/steam-export`.

## Context

The importer reads SteamExport v1, but main does not yet write the full owned-games export. Steam’s local files prove installed state and record play data, not complete ownership. The earlier game-library spec excluded the writer from v0.1.0; this decision replaces that scope limit.

## Decision

The injected dylib registers a WebUI route using the same mechanism as compatsvc’s routes. A random token is generated for each Steam launch. Only Cartouche’s injected page script receives that token. The script sends the signed-in account’s owned games through the route. The dylib validates the token and payload, then atomically writes `steam-library.json` in SteamExport v1 format. Failed validation leaves the previous export untouched.

The app consumes the export for the full owned-games list. When Steam is closed, it uses the last account-matched export even when stale, with a cached/stale label. Appmanifests supply installed status. `localconfig.vdf` supplies play data only, never ownership. ADR 0021 still applies.

## Alternatives rejected

- Loopback HTTP: any page could attempt to write the export through the local listener.
- A public Steam profile: it requires changing profile privacy and is not the authenticated local-client export.
- A user Web API key: users should not need to obtain or store a key for this feature.

## Consequences

The route is not a general file-write API. Other page scripts must not obtain the per-launch token. Tests must reject missing, incorrect and previous-launch tokens, reject malformed payloads without replacing the cache, and prove an interrupted write preserves a readable previous file. Real Steam tests must verify the owned list, refresh and account isolation. No new network service or Steam profile permission is required.
