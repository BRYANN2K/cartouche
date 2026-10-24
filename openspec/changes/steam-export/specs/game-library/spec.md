# Game library delta

## MODIFIED Requirements

### Requirement: Steam library import
The app SHALL use the signed-in Steam account’s SteamExport v1 `steam-library.json` for the full owned-games list, collections and play data. The injected dylib SHALL register a WebUI route using the same mechanism as compatsvc’s routes. The route SHALL require a random token generated per Steam launch and known only to Cartouche’s injected page script. The dylib SHALL validate the token and payload before atomically replacing the export. This writer is required for v0.1.0 (maintainer decision 2026-10-20; ADR 0022).

In review on `fix/steam-compat-tools` (not merged): the injected page script SHALL fetch the token at run time from the dylib’s `/cartouche/steam-export-token` route, served no-store, instead of carrying it in the injected source. A failed fetch SHALL be retried with backoff starting at 15 seconds and capped at 300 seconds.

The importer SHALL merge installed games and installed status from `appmanifest_*.acf`. It SHALL use `localconfig.vdf` for play data only, never ownership. An export from a different known account SHALL NOT populate the current account’s library. No loopback HTTP listener, public Steam profile or user Web API key SHALL be required.

#### Scenario: Import from Steam
- **WHEN** Steam is running and signed in with an account that has N owned games, including uninstalled games, and its injected page submits a valid export
- **THEN** within 10 seconds the library shows those N owned games, merges any additional installed games from manifests, and names the signed-in account in the toolbar

#### Scenario: Token fetched at run time
- **WHEN** the injected page script is ready to export and has no token yet
- **THEN** it requests `/cartouche/steam-export-token` with no-store, receives the per-launch token, and presents it to the export route (in review on `fix/steam-compat-tools`)

#### Scenario: Token fetch retried
- **WHEN** a token request fails or the route is not yet available
- **THEN** the script retries with backoff starting at 15 seconds and capped at 300 seconds, and exports once a token is returned (in review on `fix/steam-compat-tools`)

#### Scenario: Reject an unauthorized page
- **WHEN** a route request has no token, an incorrect token, or a token from a previous Steam launch
- **THEN** the dylib rejects the request and the previous export remains unchanged

#### Scenario: Reject invalid export data
- **WHEN** a request has the current token but an invalid SteamExport v1 payload
- **THEN** the dylib rejects the payload and the previous export remains readable and unchanged

#### Scenario: Atomic replacement
- **WHEN** writing a valid replacement is interrupted before the atomic replacement completes
- **THEN** the previous export remains readable and the app never reads a partial replacement

#### Scenario: Steam closed
- **WHEN** Steam is closed and an account-matched export exists, even if stale
- **THEN** the library shows that last export with a cached/stale label and installed status from manifests, without inferring ownership from localconfig.vdf

#### Scenario: No matching export
- **WHEN** no export exists for the current known account
- **THEN** the library shows installed games from manifests without claiming a complete owned-games list, and play data alone creates no library entry

#### Scenario: Account isolation
- **WHEN** the stored export belongs to a different known Steam account
- **THEN** the importer ignores that export for the current account

#### Scenario: Steam not installed
- **WHEN** Steam is not installed
- **THEN** the Steam source shows "Install Steam" with Download Steam (Valve installer), Install with Homebrew (only if Homebrew is present) and Locate Steam

