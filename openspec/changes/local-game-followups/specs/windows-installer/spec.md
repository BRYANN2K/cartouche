# Local-game follow-ups delta

## MODIFIED Requirements

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
An installed Windows game SHALL use local GOG/Steam identity first, then installer title where present, engine metadata, PE product information, executable name and folder names to find a known Steam App ID. A shared Steam store lookup path SHALL serve automatic fallback and user-requested cover search only when Fetch Mac reports from MacGamingDB permits online lookups. A match SHALL bring the cover, compatibility data and recommended setup; no match SHALL use a local name-and-icon placeholder. A user cover choice SHALL take priority.

#### Scenario: Matched by installer title
- **WHEN** an Inno installer titled "CarX Street" is analyzed
- **THEN** the game is matched to its Steam App ID and the review step shows its Steam cover

#### Scenario: GOG installer
- **WHEN** the installed folder contains `goggame-1207658924.info`
- **THEN** the GOG ID is used first, and the cover comes from GOG or from the matching Steam entry

#### Scenario: User corrects the match
- **WHEN** the match is wrong and the user picks another game from the search field in the review step
- **THEN** the cover, compatibility data and recommended setup switch to the chosen game


## ADDED Requirements

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

