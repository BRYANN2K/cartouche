# Unified Add Games delta

## MODIFIED Requirements

### Requirement: Adding games by checksum
Console games routed by automatic detection from the unified Add Games sheet or found in a watched folder SHALL be identified by checksum (CRC32, then MD5/SHA-1 for discs) against the libretro database, SHALL get their console and name from it, and unknown files SHALL ask for a console.

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

#### Scenario: ROM routed from Add Games
- **WHEN** the user drops or chooses ROM files or a ROM archive through the common Add Games entry point
- **THEN** automatic detection routes them to console import, extracting supported archives first, without a separate Console Games… entry

#### Scenario: Back to the common sheet
- **WHEN** the user goes Back from console identification
- **THEN** the common Add Games sheet is shown without a Windows/Console mode selector

