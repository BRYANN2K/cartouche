# Proposal

## Why

Many players own games on Epic, GOG and Amazon. Their Mac launchers run only Mac games, and Amazon has none. Open-source clients (legendary, gogdl with comet, nile) can download and launch the Windows versions; Heroic proves the approach.

## What Changes

- Sign in to Epic Games, GOG and Amazon Games through each store's own page; tokens kept in the Keychain.
- List, download, update, verify and launch their games with the chosen runner and backend.
- Cloud saves where the client supports them; GOG online features through comet.
- Import games already installed by another launcher.
- Non-goals: EA app, Ubisoft Connect, Battle.net (installed as Windows installers through P6).
- Depends on P5 and P6.

## Capabilities

### New Capabilities
- `store-integrations`: connecting to non-Steam stores and managing their games.

### Modified Capabilities
- None.

## Impact

Bundled CLIs (GPL-3.0, Apache-2.0 for comet), a store adapter per client, sign-in screens, THIRD-PARTY-LICENSES.
