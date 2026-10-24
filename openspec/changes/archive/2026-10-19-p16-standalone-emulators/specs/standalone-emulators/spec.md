## ADDED Requirements

### Requirement: Detection
Cartouche SHALL detect supported standalone emulators installed in /Applications or ~/Applications and show their version.

#### Scenario: Dolphin installed
- **WHEN** Dolphin.app is in /Applications
- **THEN** Settings > Consoles lists Dolphin with its version, and GameCube and Wii offer it as their emulator

### Requirement: Launch with the chosen emulator
For a console set to a standalone emulator, Play SHALL launch the game with that emulator's documented arguments and track it as playing until it quits.

#### Scenario: GameCube game in Dolphin
- **WHEN** GameCube is set to Dolphin and the user presses Play
- **THEN** Dolphin starts the game directly (batch mode, no Dolphin menu), the activity slot shows Playing, and quitting Dolphin clears it

#### Scenario: Emulator removed
- **WHEN** the chosen emulator is uninstalled
- **THEN** the console falls back to RetroArch if a core exists, otherwise Play shows "Dolphin is not installed"
