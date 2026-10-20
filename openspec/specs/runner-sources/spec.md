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
- **THEN** Runners shows it as "Not found" with a "How to Get It" link to Apple's page, and D3DMetal is not offered as a backend unless CrossOver provides it
