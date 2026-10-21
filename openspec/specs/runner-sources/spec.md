# runner-sources Specification

## Purpose
Free runners Cartouche can install and use without CrossOver: Wine CrossOver built by CI from CodeWeavers' LGPL sources, WineHQ builds, and Apple's Game Porting Toolkit copied from the user's own install, never redistributed.

## Requirements

### Requirement: Pinned free Wine builds
The app SHALL install only Wine builds listed in its runner manifest, and SHALL verify each download against the manifest's SHA-256 before using it.

#### Scenario: Remote manifests are signed
- **WHEN** the app fetches a newer `runners.json` from the compat-data release
- **THEN** it is used only when the detached `runners.json.sig` signature verifies against the EdDSA public key the app ships (SUPublicEDKey); a manifest with a missing or wrong signature is refused and the bundled manifest stays in use

#### Scenario: Install a pinned build
- **WHEN** the user clicks Download on "Wine CrossOver 26.3" in Runners
- **THEN** the archive is downloaded, its SHA-256 matches the manifest, and the runner appears with state ready; after explicit test-prefix initialization has finished successfully, `winecfg` reaches its window within 60 seconds on an M-series Mac (initialization time is measured separately)

#### Scenario: Tampered download is rejected
- **WHEN** the downloaded archive's SHA-256 differs from the manifest
- **THEN** the file is deleted, the runner stays not installed, and the user sees "The download was damaged. Try again."

### Requirement: Published CrossOver Wine default
The app SHALL pin the published `wine-crossover-26.3.0-1-x86_64.tar.xz` asset from `BRYANN2K/cartouche-wine` in its runner manifest with size `149444708` bytes and SHA-256 `60400817826a053599193aa290d4e24e97213a743195f4187400bf9c74906887`. New games SHALL default to this CrossOver Wine runner. Existing explicit per-game runner choices SHALL remain unchanged.

#### Scenario: Published build is offered
- **WHEN** the app offers its default free runner for a new game
- **THEN** it selects CrossOver Wine and uses the published release URL, size and SHA-256 above for any required download

#### Scenario: Existing choice is preserved
- **WHEN** a game already has an explicit runner choice and the new default becomes available
- **THEN** that game retains its runner choice

### Requirement: Explain unavailable Graphics choices
The Graphics menu SHALL explain unmet backend requirements. D3DMetal SHALL require CrossOver-capable Wine, Rosetta and the user’s own D3DMetal files. DXMT SHALL require CrossOver and its backend download. Get More Graphics Backends SHALL open Settings > Compatibility. A WineHQ runner alone or GPTK files without CrossOver Wine SHALL NOT satisfy that combination. Cartouche SHALL NOT redistribute GPTK or D3DMetal files.

#### Scenario: Missing CrossOver Wine
- **WHEN** a game uses another Wine variant and the user inspects D3DMetal
- **THEN** the menu explains that CrossOver Wine is required, rather than implying that GPTK files alone enable it

#### Scenario: Missing GPTK files
- **WHEN** a game uses CrossOver Wine but the user’s GPTK files are unavailable
- **THEN** the menu explains that the user must supply GPTK files and D3DMetal is unavailable

### Requirement: Serialized first boot before launch
The app SHALL treat fresh-prefix initialization as an explicit setup phase, serialized per prefix. It SHALL await successful boot completion and Wine-server completion before starting an installer or game in that prefix. A registry file or update timestamp alone SHALL NOT prove readiness. Setup SHALL show progress or phase status, logs, cancellation and retry. The Wine CI initialization limit SHALL NOT set the app’s first-boot timeout.

#### Scenario: Launch requested during initialization
- **WHEN** initialization is active and another launch is requested for the same prefix
- **THEN** no second initialization or game or installer process starts in that prefix before initialization finishes successfully

#### Scenario: Initialization succeeds
- **WHEN** explicit initialization and the Wine server finish successfully
- **THEN** the app permits the waiting installer or game to start

#### Scenario: Initialization fails or is cancelled
- **WHEN** first boot fails or the user cancels it
- **THEN** the app does not launch the installer or game, exposes the setup log and offers retry without treating leftover registry files as proof of readiness

### Requirement: Separate Wine CI initialization and window checks
The Wine build CI SHALL run `wineboot -i` with `WINEDLLOVERRIDES=mscoree,mshtml=` for CI initialization only, then `wineserver -w`, under the 20-minute initialization limit `BOOT_INIT_LIMIT`. It SHALL log initialization time and run the existing 60-second winecfg window check only after successful initialization. This CI limit SHALL NOT define the app’s first-boot timeout.

#### Scenario: Successful initialization
- **WHEN** Wine CI initializes a fresh test prefix successfully and the Wine server finishes within BOOT_INIT_LIMIT
- **THEN** CI logs initialization time and starts the separate 60-second winecfg window check

#### Scenario: Initialization fails or exceeds its limit
- **WHEN** prefix initialization fails or the initialization phase exceeds BOOT_INIT_LIMIT
- **THEN** the boot check fails at initialization and does not claim a successful winecfg window check

### Requirement: Steam Play hooks on free builds
Each supported free Wine build SHALL have pinned ntdll hook offsets so that Steam games started through it get the Steam client integration NotProton provides on CrossOver.

#### Scenario: Steam API reaches the game
- **WHEN** a Steam game known to call the Steam API at start (e.g. one that shows the Steam overlay) is launched through the free runner
- **THEN** the game starts, the log shows lsteamclient loaded, and Steam marks the game as running

### Requirement: Game Porting Toolkit detection
The app SHALL detect a Game Porting Toolkit installed by the user and offer it as a runner, and SHALL NOT include any D3DMetal or GPTK file in the repository, a release asset, or a download it hosts.

#### Scenario: GPTK found
- **WHEN** the user has installed the Game Porting Toolkit from Apple's disk image
- **THEN** Runners lists "Game Porting Toolkit" with its version and asks once, showing the size a copy needs: Copy into Cartouche's runners folder, or Use in Place

#### Scenario: Copied
- **WHEN** the user answers Copy
- **THEN** the toolkit is copied into Cartouche's runners folder and the runner reaches state ready

#### Scenario: Used in place
- **WHEN** the user answers Use in Place
- **THEN** the runner records the folder, keeps no copy, and reaches state ready while that folder is there

#### Scenario: The in-place folder is gone
- **WHEN** a folder recorded by Use in Place no longer exists
- **THEN** the runner shows a damaged state naming the folder and offers to copy the toolkit from a new location

#### Scenario: Nothing Apple is redistributed
- **WHEN** CI scans the repository and every release asset for D3DMetal or GPTK file names and Apple's library hashes
- **THEN** the scan finds no match and the job passes

#### Scenario: GPTK absent
- **WHEN** no Game Porting Toolkit is installed
- **THEN** Runners shows it as "Not found" with a "How to Get It" link to Apple’s page, and the default CrossOver Wine runner’s Graphics menu explains that D3DMetal needs the user’s GPTK files
