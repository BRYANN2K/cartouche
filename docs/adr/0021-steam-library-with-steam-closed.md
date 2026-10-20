# 0021. Steam library with Steam closed

## Status

Accepted, 2026-10-20. 

## Context

Steam local files do not provide a complete, current plaintext ownership list. Activity metadata must not create owned-library entries.

## Decision

When Steam is closed, show the last account-matched steam-library.json export and label it cached and potentially stale. Use appmanifest files for installed status and for installed games absent from the export. Read localconfig.vdf only for play data, never ownership. A complete owned-library refresh comes from the authenticated Steam client, not a title list inferred from play history.

## Alternatives rejected

Do not treat localconfig.vdf, collections or appinfo.vdf as an entitlement ledger. Do not claim that cached ownership is current.

## Consequences

The importer already merges exports with installed manifests and applies play data only to known games. Preserve the cached/stale label and account isolation. Real Steam export freshness remains a manual validation task.
