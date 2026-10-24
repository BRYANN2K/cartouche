# Proposal

## Why

Controllers and keyboards must just work, for PC and console games alike, and players must be able to change what each button does. The study in `docs/research/controls.md` shows what is possible with free signing.

## What Changes

- Controller status (name, battery) from Apple's Game Controller framework, in the game panel and Settings > Controllers.
- Per-game remapping: Steam Input for Steam games (open in Steam), `SDL_GAMECONTROLLERCONFIG` for other Wine games, RetroArch remap files for console games.
- Mac keyboard and mouse options for Wine games: Command as Control, Option as Alt, keep the mouse in the window, precise scrolling.
- Controller for keyboard-only games, by posting keyboard and mouse events (Accessibility permission).
- Couch mode: navigate Cartouche with a controller.
- Non-goals: a system-wide virtual controller (needs an Apple entitlement unavailable with free signing). A virtual XInput pad inside our Wine build is a later spike.
- Depends on P5, P6, P13.

## Capabilities

### New Capabilities
- `controls`: controller status, remapping, keyboard and mouse options, and couch mode.

### Modified Capabilities
- None.

## Impact

Game Controller framework use in the app, launch environment for Wine games, Wine Mac driver registry keys per prefix, RetroArch remap files, an input-posting helper.
