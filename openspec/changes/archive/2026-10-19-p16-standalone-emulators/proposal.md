# Proposal

## Why

Some consoles run best in standalone emulators (Dolphin for GameCube and Wii, PCSX2 for PS2, PPSSPP, Azahar for 3DS, xemu, Ryubing). Players who installed them should see those games in the same library, launched with the right emulator.

## What Changes

- Detect installed standalone emulators and their versions.
- Per console, choose RetroArch or a detected standalone emulator.
- Launch games with each emulator's documented command line, and show them as playing.
- Non-goals: installing or bundling standalone emulators; anything beyond launch and quit for them.
- Depends on P13.

## Capabilities

### New Capabilities
- `standalone-emulators`: detecting and launching games with standalone emulators.

### Modified Capabilities
- None.

## Impact

An emulator catalog with detection paths and launch arguments (from `docs/research/bonus-emulators.md`), a per-console emulator setting.
