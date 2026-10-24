# Proposal

## Why

Players want to know how well a game really runs on their Mac and which setup is best. Community estimates help before playing; after playing, their own numbers are better.

## What Changes

- Measure frames presented through Metal in the game process, for every backend, and store sessions locally.
- Show the user's average FPS, 1% low and play time per game, and a comparison of every setup they tried.
- Opt-in sharing of results with MacGamingDB.
- Non-goals: an in-game overlay beyond Apple's Metal HUD; automatic benchmarking (P11 agent tool).
- Depends on P3.

## Capabilities

### New Capabilities
- `performance-tracking`: measuring, storing, presenting and optionally sharing frame rates per game and setup.

### Modified Capabilities
- None.

## Impact

A small frame-counter library injected into the Wine process (x86_64 and arm64), a local SQLite store, the Your Play section and the setup comparison sheet. PRIVACY doc.
