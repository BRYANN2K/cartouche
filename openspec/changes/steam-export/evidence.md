# Steam export implementation evidence

## Merged implementation

Implementation commit 451e393, merged to main in de0e6ec on 2026-10-20.

- libexport registers `Cartouche.ExportOwnedGames#1` through the WebUI route mechanism using `CTransportValidation_CountOrderedBytes`.
- The page uses SteamClient WebUI transport: `TransportAuth.Authenticate`, then the export frame with the per-launch token prefix.
- Owned games come from `appStore.m_mapApps`: `BIsOwned`, not borrowed or shortcuts, app type game. Hidden state comes from `collectionStore`.
- The page polls every 15 seconds and sends only changed data.
- The dylib limits the payload to 4 MB, validates SteamExport v1, Steam ID against loginusers, field types and name length. It atomically writes mode 0600 and refuses symlinked directories or targets.

## Automated results reported by the integration owner

- `libexport-check`: 0 failures.
- `library-export.js`: 20 checks.

This documentation update inspected the merged source but did not rerun these suites. The reported results do not prove real Steam behavior.

## Pending manual checks

On real Steam: compare the full owned list including uninstalled games, ensure borrowed/shortcut entries are absent, change the owned/hidden state and observe refresh, switch accounts and check isolation, close Steam and confirm the last export remains labelled cached/stale. Check token rotation and failed-write recovery against the integrated app as needed. Do not mark the change fully verified or archive it until the remaining acceptance evidence is recorded.
