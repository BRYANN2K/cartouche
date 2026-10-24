# controls Specification

## Purpose
Cartouche shows controller status and maps controllers and keyboards for each game: RetroArch remaps, Steam Input for Steam games, SDL mappings and Mac keys for Wine games, a controller-to-keyboard helper, and couch-mode focus navigation.

## Requirements

### Requirement: Controller status
Cartouche SHALL show connected controllers with their name and battery level.

#### Scenario: DualSense
- **WHEN** a DualSense is connected over Bluetooth
- **THEN** Settings > Controllers and the game panel show "DualSense" with a battery percentage within 2 seconds

### Requirement: Remapping per game
Users SHALL change button actions per game: through Steam Input for Steam games, through an SDL mapping for other Wine games, and through a RetroArch remap file for console games.

#### Scenario: Wine game remap
- **WHEN** the user swaps Cross and Circle for a non-Steam Wine game and launches it
- **THEN** the launch environment contains the matching `SDL_GAMECONTROLLERCONFIG` entry and the game reacts to Circle where it reacted to Cross

#### Scenario: Steam game
- **WHEN** the user opens Customize on a Steam game
- **THEN** Cartouche shows "Steam Input handles this game" with Open in Steam, and changes nothing itself

#### Scenario: Console game
- **WHEN** the user picks Swap A/B for a SNES game
- **THEN** a RetroArch remap file for that game is written and the swap applies at next launch

### Requirement: Mac keyboard and mouse in Wine games
The Keyboard and Mouse options SHALL set the Wine Mac driver keys for that game's prefix.

#### Scenario: Command as Control
- **WHEN** Command acts as Control is on and the user presses Command-C in a Wine game's text field
- **THEN** the game receives Control-C

### Requirement: Controller for keyboard-only games
With the option on and Accessibility granted, Cartouche SHALL turn controller input into keyboard and mouse events for that game only, and SHALL stop when the game is not frontmost.

#### Scenario: Only while the game is frontmost
- **WHEN** the user switches from the game to another app
- **THEN** no key or mouse event is posted until the game is frontmost again

### Requirement: Couch mode
With couch mode on, the user SHALL be able to browse the library, open a game and press Play with a controller only.

#### Scenario: Controller only
- **WHEN** the keyboard and trackpad are not touched
- **THEN** the user can go from launch to a running game with D-pad and buttons, with a visible focus ring at every step
