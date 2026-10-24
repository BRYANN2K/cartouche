# console-extras Specification

## Purpose
Cartouche adds console extras on top of RetroArch: netplay through the libretro lobby, RetroAchievements with Hardcore, a translation service setting, iCloud Drive saves and states, and named game values for Coach mode.

## Requirements

### Requirement: Netplay
The user SHALL be able to host a console game for friends and join a friend's game from Cartouche, using RetroArch netplay and libretro's lobby.

#### Scenario: Host and join
- **WHEN** player A clicks Host on a SNES game and player B, on another Mac with Cartouche, opens Join
- **THEN** B sees A's game in the list, joins, and both control their own player within 10 seconds on the same network

### Requirement: RetroAchievements
After a one-time sign-in, the panel SHALL show unlocked and total achievements per game, and Hardcore mode SHALL disable save states and rewind for that game.

#### Scenario: Counts match the site
- **WHEN** the user is signed in and opens a game they played
- **THEN** the unlocked count equals the one on retroachievements.org for that game and account

#### Scenario: Hardcore
- **WHEN** Hardcore is on
- **THEN** Continue From and rewind are disabled for that game, and RetroArch reports hardcore active

### Requirement: Screen translation
When a translation service is configured, the user SHALL be able to translate the current screen; without one, the option SHALL explain what is missing.

#### Scenario: Not configured
- **WHEN** no translation service is set
- **THEN** the toggle reads "Needs a translation service, set in Settings" and does nothing else

### Requirement: Saves in iCloud Drive
With the option on, save files and save states SHALL be stored in iCloud Drive so they follow the user to another Mac.

#### Scenario: Two Macs
- **WHEN** a state is saved on Mac A and Cartouche starts on Mac B after iCloud sync
- **THEN** Mac B's Continue From shows that state

### Requirement: Coach mode
Coach mode SHALL be off by default, marked experimental, read game values only through Cartouche's MCP relay, and never send input in Hardcore mode.

#### Scenario: Reads, never cheats
- **WHEN** Coach mode is on in a Hardcore session and an agent asks to press a button
- **THEN** the request is refused with "Hardcore mode", while reading named values still works
