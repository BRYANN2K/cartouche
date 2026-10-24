# windows-installer Specification

## Purpose
How Cartouche inspects a Windows installer and its parts without running anything, installs the game into its own prefix, diagnoses and retries failures, picks the game's executable and adds it to the library.

## Requirements

### Requirement: Common Add Games entry
Windows installers and installed-game folders SHALL enter through the unified Add Games sheet, opened by the toolbar + or a library-window drop. The sheet SHALL offer a drop zone and Choose… for files or folders of any type. Automatic classification SHALL route installers to installer analysis and installed-game folders to import; it SHALL NOT require a separate Windows Games… entry or execute a game as a setup merely because it is an exe.

#### Scenario: Installer routed from Add Games
- **WHEN** the user drops or chooses an installer or its folder through Add Games
- **THEN** automatic detection opens the installer flow with those inputs, without requiring a platform choice

#### Scenario: Installed game routed from Add Games
- **WHEN** the user drops or chooses an already-installed Windows-game folder through Add Games
- **THEN** automatic detection opens the installed-game import flow rather than running its executable as setup

### Requirement: Direct extraction for supported external unpackers
For supported installers with external unpackers, Cartouche SHALL extract the parts through its own unpacker driver without executing setup.tmp or ISDone. Unknown formats SHALL retain the normal installer path or report unsupported extraction clearly. Support SHALL be based on verified recipes, not inferred from a .bin extension. Recipe evidence SHALL be distinguished from completed app integration.

#### Scenario: Verified CarX Street recipe
- **WHEN** the CarX Street test case is extracted with the CLS Init_MapFile_ driver and unarc.dll FreeArcExtract under WineHQ 11.18
- **THEN** the direct recipe exits successfully, all 905 real files pass MD5 verification with zero mismatches, output totals 22,703,585,753 bytes, and CarX Street.exe is present; the malformed wildcard row is reported separately from real files

#### Scenario: No setup wrapper on direct path
- **WHEN** the supported direct-unpack path runs
- **THEN** process evidence shows no setup.tmp or ISDone execution

#### Scenario: Unsupported external-unpacker format
- **WHEN** parts do not match a verified direct-unpack recipe
- **THEN** Cartouche does not claim successful direct support and offers the normal installer path or a clear unsupported-extraction message

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

### Requirement: Static classification with evidence and confidence
Detection SHALL use static inspection only (filenames, sizes, magic, PE structure and overlay, archive parser results, sidecars, volume families) and SHALL report evidence and a confidence level for every classification (ADR 0028). Ambiguous or conflicting evidence SHALL be shown to the user; an unknown executable SHALL NOT run by default.

#### Scenario: Inno beyond the supported range
- **WHEN** innoextract reports an Inno data version beyond its recorded supported range (innoextract 1.9: Inno 1.2.10–6.2.2)
- **THEN** the input is classified as Inno-like and unsupported, not as a generic archive

#### Scenario: Runtime decompressor helpers
- **WHEN** an Inno installer references helpers such as ISDone.dll, unarc.dll or CLS-*.dll
- **THEN** it is classified as an installer requiring runtime behavior and is not claimed reproducible by static extraction alone

#### Scenario: Incomplete archive set
- **WHEN** a multi-volume archive set is missing a required volume
- **THEN** the missing volume is named and extraction is blocked

#### Scenario: Portable build
- **WHEN** extracted contents match an installed-game layout
- **THEN** the input is classified as a portable build and no redistributable is run automatically

#### Scenario: Conflicting evidence
- **WHEN** markers disagree about an input's type
- **THEN** the observed facts and confidence are presented and the user decides

#### Scenario: Unknown executable
- **WHEN** an executable matches no known format
- **THEN** it is not run by default

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
- **WHEN** the chosen executable or adjacent DLLs import a runtime not already supplied beside the game
- **THEN** PE-based detection selects its winetricks step rather than running bundled redistributable installers

#### Scenario: Cleanup is never automatic
- **WHEN** the install is done
- **THEN** the installer files stay in place until the user clicks Delete and confirms, and then they go to the Trash

### Requirement: Identify the game and its cover
An installed Windows game SHALL use local GOG/Steam identity first, then installer title, engine metadata, PE product information, executable and folder names to find a Steam App ID. Steam store lookups SHALL run only when Fetch Mac reports from MacGamingDB permits online lookups. A match SHALL bring the cover, compatibility data and recommended setup; no match SHALL use a name-and-icon placeholder. A user cover choice SHALL take priority.

#### Scenario: Matched by installer title
- **WHEN** an Inno installer titled "CarX Street" is analyzed
- **THEN** the game is matched to its Steam App ID and the review step shows its Steam cover

#### Scenario: GOG installer
- **WHEN** the installed folder contains `goggame-1207658924.info`
- **THEN** the GOG ID is used first, and the cover comes from GOG or from the matching Steam entry

#### Scenario: User corrects the match
- **WHEN** the match is wrong and the user picks another game from the search field in the review step
- **THEN** the cover, compatibility data and recommended setup switch to the chosen game

### Requirement: PE-based runtime steps
Runtime detection SHALL inspect the selected executable’s PE imports and adjacent DLLs, avoid installing DLL families already supplied beside the game, and use Wine Mono for .NET. Required winetricks verbs SHALL run one at a time with a timeout and Skip. The current implementation uses 300 seconds per verb.

#### Scenario: One runtime at a time
- **WHEN** several runtime verbs are required
- **THEN** only one verb runs at a time and the UI shows each step’s status

#### Scenario: Runtime skipped or timed out
- **WHEN** the user skips a running step or it exceeds the verb timeout
- **THEN** that step is marked skipped and setup can proceed to the next step without treating it as installed

### Requirement: Safe installer-game removal
Managed installer games SHALL be moved to the Trash on uninstall after confirmation. Keep save files SHALL copy detected prefix save folders out before trashing. In-place imported games SHALL offer Remove from Library and move only Cartouche’s prefix and record to the Trash, never the source game folder.

#### Scenario: Managed uninstall with saves
- **WHEN** the user confirms uninstall with Keep save files enabled
- **THEN** detected prefix save folders are copied locally before the managed game and prefix move to the Trash; a failed save copy leaves the game in place

#### Scenario: Remove in-place import
- **WHEN** the user confirms Remove from Library for an in-place import
- **THEN** only Cartouche’s prefix and record move to the Trash and source game files remain unchanged

### Requirement: Verified output before installed status
The app SHALL separate installed and verification states: full (mandatory shipped checksum or archive CRC), partial (script presence/sizes; “verified (sizes)”), or unavailable (“Installed, not verified” with a discreet badge and panel line). It SHALL NOT offer a skip checkbox. Process success or executable presence alone SHALL NOT imply verification. Stop during verification SHALL mark not verified.

#### Scenario: Shipped checksum manifest
- **WHEN** installation output has a shipped checksum manifest
- **THEN** the app always verifies against it before assigning a fully verified status, with no skip option

#### Scenario: Archive CRC
- **WHEN** archive CRC is available without a shipped checksum list
- **THEN** the app always verifies archive integrity as full verification, without requiring an installer script file list for that level

#### Scenario: Partial evidence only
- **WHEN** no checksum is available but the installer script supplies a file list and sizes
- **THEN** the app checks presence and sizes and labels passing output “verified (sizes)”, not fully verified

#### Scenario: No verification evidence
- **WHEN** the installer supplies neither checksum/CRC evidence nor a usable file list and sizes
- **THEN** installation is allowed with “Installed, not verified”, a discreet badge and a game-panel line

#### Scenario: Stop verification
- **WHEN** the user presses Stop during verification
- **THEN** verification stops and the game is marked not verified

### Requirement: Ordered verification fallback
On verification failure or mismatch the app SHALL show “Some files don’t match” with Retry with the standard method as the default action, Keep Anyway as an advanced action, and Cancel. Retry SHALL start fallback with shipped helpers and original settings. If that path fails, guided execution of the real installer under Wine SHALL be the last resort. Every result SHALL retain the appropriate verification level; no fallback exit alone implies verified output.

#### Scenario: Optimized extraction mismatch
- **WHEN** an optimized extraction fails verification
- **THEN** the failure sheet offers the three actions and defaults to Retry with the standard method, which starts the shipped-helper/original-settings retry when chosen

#### Scenario: Keep mismatched output
- **WHEN** the user chooses Keep Anyway
- **THEN** the game is marked not verified and mismatched files are listed in the log

#### Scenario: Cancel after mismatch
- **WHEN** the user chooses Cancel in the mismatch sheet
- **THEN** no retry starts and the output is not marked verified

#### Scenario: Original-helper retry fails
- **WHEN** the original-helper retry fails
- **THEN** the user is offered a guided real-installer run under Wine as last resort and its result receives the applicable verification status

### Requirement: Verify files later
The game menu SHALL offer Verify Files… for later verification, including when the user supplies a checksum list. Later verification SHALL apply the same mandatory evidence checks and failure choices.

#### Scenario: Checksum list supplied later
- **WHEN** the user supplies a checksum list and chooses Verify Files… for a not-verified game
- **THEN** the files are checked against it and verified status is granted only on success

### Requirement: Output-preserving optimizations
Optimizations SHALL change speed only, not output. Native helper replacements SHALL be selected only for exact helper versions matched by a hash allowlist; unknown versions SHALL use the shipped Windows helpers. Each optimization SHALL produce byte-identical output on the local regression corpus, including the user-owned CarX Street, Lost in Random and Silksong RAR cases where applicable. Corpus files and verification data SHALL never leave the Mac.

#### Scenario: Unknown helper hash
- **WHEN** a helper version is not an exact hash-allowlist match
- **THEN** the native replacement is not used and the shipped Windows helper is used instead

#### Scenario: Regression comparison
- **WHEN** an optimization is proposed for supported helper versions
- **THEN** its output is compared byte-for-byte with the original path on applicable local corpus cases and any output difference blocks acceptance of that optimization

#### Scenario: Local corpus only
- **WHEN** regression verification runs
- **THEN** corpus files and verification data remain on the Mac and are not uploaded
