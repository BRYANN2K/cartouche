# windows-installer Specification

## Purpose
How Cartouche inspects a Windows installer and its parts without running anything, installs the game into its own prefix, diagnoses and retries failures, picks the game's executable and adds it to the library.

## Requirements

### Requirement: Analysis without execution
Before anything runs, the app SHALL report the installer type, its parts, missing parts, checksum results, the identified game and the space needed, and SHALL NOT execute any file from the dropped folder during analysis.

#### Scenario: Multi-part Inno installer
- **WHEN** a folder with setup.exe, data-01.bin, data-02.bin and MD5/checksums.md5 is dropped
- **THEN** the analysis shows Inno Setup 5.5, 2 parts (11.1 GB), heavy decompression, both checksums OK, and completes the checks within 30 seconds on an M4

#### Scenario: Missing part
- **WHEN** data-02.bin is removed and the manifest does not mark parts as optional
- **THEN** the missing file is named in red, Install is disabled, and Check Again is offered

#### Scenario: Optional parts
- **WHEN** a part is missing and the manifest says some parts are optional downloads
- **THEN** the missing file is shown in orange as "may be optional" and Install stays enabled

#### Scenario: No execution
- **WHEN** analysis runs under a process monitor
- **THEN** no process is started from the dropped folder; only innoextract and the app read it

### Requirement: Installation with real progress
The app SHALL run the installer in a dedicated prefix with the chosen runner under Rosetta, pass the install folder and log options, and show progress from the bytes written to the install folder.

#### Scenario: Install completes
- **WHEN** the user installs a test Inno installer in Guided mode
- **THEN** the installer window opens with the install folder prefilled, progress rises with the folder size, and the flow moves to "Which file starts the game?" when the installer exits with code 0

#### Scenario: Background install
- **WHEN** the user clicks Continue in Background
- **THEN** the sheet closes, the activity card shows progress, and a notification "<Game> is installed" with Open appears at the end

#### Scenario: Stuck installer
- **WHEN** the install folder does not grow for 5 minutes and CPU use of the installer is under 2%
- **THEN** the app shows "The installer seems stuck" with Show Installer Window and Stop

### Requirement: Failure and retry
When an install fails, the app SHALL name the likely cause from the exit code and log, and SHALL offer retries with specific fixes.

#### Scenario: Decompression error
- **WHEN** the installer log contains an unarc.dll or ISDone.dll error
- **THEN** the app shows the probable causes in order (memory, path, damaged file) and offers Verify Files, Retry with Fewer Threads and Retry with Less Memory

### Requirement: Playable result
After a successful install the game SHALL appear in the library with its executable chosen, its redistributables provided through Wine equivalents, and an optional Steam shortcut.

#### Scenario: Executable ranking
- **WHEN** the install created a Start Menu shortcut to game.exe and also unins000.exe and a launcher exe
- **THEN** game.exe is preselected as "From the Start Menu shortcut", the launcher is second, and unins000.exe is not listed

#### Scenario: Redistributables
- **WHEN** the install folder contains `_Redist/dxwebsetup.exe` and vcredist installers
- **THEN** they are not run, the matching winetricks verbs are installed, and the summary says which

#### Scenario: Cleanup is never automatic
- **WHEN** the install is done
- **THEN** the installer files stay in place until the user clicks Delete and confirms, and then they go to the Trash

### Requirement: Identify the game and its cover
An installed Windows game SHALL be matched to a Steam App ID when possible, using in order: a GOG `goggame-<id>.info` file, the installer title read by innoextract, the executable's product name, and the cleaned folder name, searched in the compatibility data and MacGamingDB. A match SHALL bring the cover, the compatibility data and the recommended setup; no match SHALL fall back to the name-and-icon cover.

#### Scenario: Matched by installer title
- **WHEN** an Inno installer titled "CarX Street" is analyzed
- **THEN** the game is matched to its Steam App ID and the review step shows its Steam cover

#### Scenario: GOG installer
- **WHEN** the installed folder contains `goggame-1207658924.info`
- **THEN** the GOG ID is used first, and the cover comes from GOG or from the matching Steam entry

#### Scenario: User corrects the match
- **WHEN** the match is wrong and the user picks another game from the search field in the review step
- **THEN** the cover, compatibility data and recommended setup switch to the chosen game
