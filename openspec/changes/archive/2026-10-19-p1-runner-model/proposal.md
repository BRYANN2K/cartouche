# Proposal

## Why

Runner support is hard-wired to CrossOver: discovery, cloning, ntdll patching and Steam compatibility tools all assume a CrossOver bundle. Free runners (P2) and per-game setups (P3) need one runner model first, with CrossOver as just one source.

## What Changes

- A runner model with a source kind (CrossOver, Wine build, Game Porting Toolkit), version, CPU flavors (Rosetta, FEX) and state (available, installing, ready, damaged, unsupported).
- CrossOver discovery, cloning and patching re-expressed on that model, with identical behavior.
- One runner registry the app, the Steam tools and later the installer read from.
- Non-goals: no new runner source (P2), no backend choice (P3), no UI redesign.
- Depends on P0.

## Capabilities

### New Capabilities
- `runner-management`: discovering, installing, verifying and listing runners, whatever their source.

### Modified Capabilities
- None.

## Impact

`app/Sources/NotProtonApp/Model/` (CrossOverSource, RunnerStore, RunnerInstaller, RunnerPatcher, SupportedRunner), their tests. No change to the dylib's behavior.
