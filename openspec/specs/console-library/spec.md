# console-library Specification

## Purpose
How console games live in Cartouche's library: adding consoles and games, identifying files, watched folders, covers, the console panel, Continue From and launch through RetroArch.

## Requirements

### Requirement: Consoles the user chose
The sidebar SHALL list only the consoles the user added, each with its game count; adding a console SHALL download only its core, and removing one SHALL keep the game files.

#### Scenario: Add two consoles
- **WHEN** the user opens + next to Consoles and adds NES and Game Boy
- **THEN** both appear in the sidebar, their two cores are downloaded, and no other core is

#### Scenario: Games already found are suggested
- **WHEN** the watched folder holds 4 Game Boy games and Game Boy is not added
- **THEN** the Add Consoles sheet shows "4 games found" on the Game Boy tile

#### Scenario: Remove a console
- **WHEN** the user right-clicks PlayStation and chooses Remove
- **THEN** it leaves the sidebar, its core is deleted, and every PlayStation game file is still on disk

### Requirement: Adding games by checksum
Console games added from the + sheet or found in a watched folder SHALL be identified by checksum (CRC32, then MD5/SHA-1 for discs) against the libretro database, SHALL get their console and name from it, and unknown files SHALL ask for a console.

#### Scenario: Known cartridge
- **WHEN** a No-Intro verified SNES dump of Super Metroid is dropped
- **THEN** it is listed as "Super Metroid", console Super Nintendo, "checksum match", within 2 seconds

#### Scenario: Disc image
- **WHEN** a Redump-verified PlayStation `.cue` with its `.bin` is dropped
- **THEN** it is identified by disc ID, and a multi-disc set with an `.m3u` shows as one game

#### Scenario: Unknown file
- **WHEN** a homebrew `.gba` file with no database match is dropped
- **THEN** it is listed as "Not recognized" with a console picker, and Add does not include it until a console is chosen

#### Scenario: Watched folder
- **WHEN** a recognized game file is copied into a watched folder while Cartouche runs
- **THEN** it appears in its console within 10 seconds, without opening any sheet

#### Scenario: Back and forth in the + sheet
- **WHEN** the user switches from Console Games to Windows Game and back, and goes Back from the identification step
- **THEN** each switch shows the matching first step and nothing is lost or stuck

### Requirement: Covers
Console games SHALL show box art, title screen and screenshot from libretro-thumbnails matched by database name, cached locally, on square cards that fit landscape and portrait boxes.

#### Scenario: Offline after first view
- **WHEN** covers were shown once and the Mac goes offline
- **THEN** the same covers still show

### Requirement: Console game panel
The panel SHALL show Play or Resume, Continue From with the pictures RetroArch saved with each state, play time, achievement count, Setup (core, look, input lag, Hardcore, disc for multi-disc games), Controls, and a BIOS warning when one is missing; other options SHALL be behind More….

#### Scenario: Resume from a state
- **WHEN** the user clicks the Slot 3 picture under Continue From
- **THEN** RetroArch starts the game and loads slot 3, and the game shows the moment of that picture

#### Scenario: Missing BIOS blocks Play
- **WHEN** a PlayStation game is selected and its BIOS is missing
- **THEN** Play is disabled and the panel says which file is missing and to dump it from the user's own console

#### Scenario: Look applies live
- **WHEN** the user switches Look to CRT while the game runs
- **THEN** RetroArch applies the CRT shader within 1 second and the panel's picture shows the same look

### Requirement: Launch and quit
Pressing Play SHALL start the game in RetroArch with a short CRT power-on in Cartouche, mark the game as playing in the activity slot, and Quit SHALL end it with an auto save.

#### Scenario: Quit from Cartouche
- **WHEN** the user clicks Quit in the activity slot
- **THEN** RetroArch saves the auto state and exits, the game's Continue From shows the new Auto picture, and play time increases by the session length
