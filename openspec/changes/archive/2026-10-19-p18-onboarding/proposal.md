# Proposal

## Why

First impressions decide whether a free, unnotarized app gets used. The user must get from download to a running game without hitting a wall: Gatekeeper's warning, a missing runner, a missing permission, or an empty library.

## What Changes

- Installation: a one-line install script (recommended, no Gatekeeper warning because curl downloads carry no quarantine flag), the GitHub Release dmg, or the Homebrew tap; the dmg and README show the "Open Anyway" steps for those two.
- First launch: welcome, what Cartouche found (Steam, CrossOver, GPTK, RetroArch build, controllers, existing ROM folders), what to set up (free runner download, Steam integration with App Management), consoles to add, game folders, privacy choices, ready.
- Every step skippable; everything is reachable later from Settings.
- Non-goals: a tour of every feature; account creation.
- Depends on P5 and P17.

## Capabilities

### New Capabilities
- `onboarding`: installing Cartouche and its first launch, from download to a ready library.

### Modified Capabilities
- None.

## Impact

Onboarding sheets in the app, dmg background and README install section, the Homebrew cask caveats.
