# Proposal

## Why

Cartouche must run Windows games without a paid CrossOver license. Free runners cover most games: Wine CrossOver built by Cartouche's CI from the source code CodeWeavers publishes under the LGPL (no one publishes ready builds as of 2026-10-19), official WineHQ builds, and Apple's Game Porting Toolkit with D3DMetal, which the user installs themselves.

## What Changes

- Build Wine CrossOver in CI from CodeWeavers' published sources (e.g. `crossover-sources-26.3.0.tar.gz`), publish it as a release asset, and let the app download, verify and install it.
- Offer official WineHQ macOS builds as a secondary runner.
- Detect a Game Porting Toolkit the user installed and register it as a runner, without copying D3DMetal into the repository or a release.
- Pin ntdll hook offsets for each supported free build, the same way NotProton pins CrossOver.
- Non-goals: graphics backend choice (P3); runners from third-party wrappers (Sikarugir engines).
- Depends on P1.

## Capabilities

### New Capabilities
- `runner-sources`: where free runners come from, how they are verified, and what is never redistributed.

### Modified Capabilities
- None.

## Impact

New runner source code, `ntdll-patch/` pins for the new builds, a runner manifest (URL, size, SHA-256) shipped with the app. THIRD-PARTY-LICENSES gains Wine (LGPL) notices.
