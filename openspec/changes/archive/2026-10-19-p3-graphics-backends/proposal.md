# Proposal

## Why

The graphics translation layer decides whether a game runs and how fast: D3DMetal leads on DirectX 12, DXMT on DirectX 11, DXVK on older games. Users need to choose it per game, the way Steam on Linux lets them pick a Proton version, and to pick the native Mac build when one exists.

## What Changes

- A game setup: runner, graphics backend (D3DMetal, DXMT, DXVK, wined3d), CPU translation (Rosetta, FEX), Metal HUD, environment variables.
- Steam compatibility tools for each valid runner and backend pair, named "<runner> · <backend>".
- For games with a native Mac version: a choice between the Mac version and the Windows version through Steam Play.
- DXMT and DXVK downloaded and pinned like runners.
- Non-goals: automatic backend choice from community data (uses P4 later); FPS measurement (P8).
- Depends on P2.

## Capabilities

### New Capabilities
- `game-setup`: how a game's runner, backend, CPU translation and version are chosen, stored and applied at launch.

### Modified Capabilities
- None.

## Impact

`dylib/feats/compat_run.sh` (DLL overrides and env per backend), the compat tool registration in the dylib, a per-game setup store in the app, Steam's `CompatToolMapping` written through the existing SpecifyCompatTool hook.
