# runner-sources Specification

## Purpose
Free runners Cartouche can install and use without CrossOver: Wine CrossOver built by CI from CodeWeavers' LGPL sources, WineHQ builds, and Apple's Game Porting Toolkit copied from the user's own install, never redistributed.

## Requirements

### Requirement: Pinned free Wine builds
The app SHALL install only Wine builds listed in its runner manifest, and SHALL verify each download against the manifest's SHA-256 before using it.

#### Scenario: Install a pinned build
- **WHEN** the user clicks Download on "Wine CrossOver 26.3" in Runners
- **THEN** the archive is downloaded, its SHA-256 matches the manifest, the runner appears with state ready, and a test game prefix boots `winecfg` to its window within 60 seconds on an M-series Mac

#### Scenario: Tampered download is rejected
- **WHEN** the downloaded archive's SHA-256 differs from the manifest
- **THEN** the file is deleted, the runner stays not installed, and the user sees "The download was damaged. Try again."

### Requirement: Steam Play hooks on free builds
Each supported free Wine build SHALL have pinned ntdll hook offsets so that Steam games started through it get the Steam client integration NotProton provides on CrossOver.

#### Scenario: Steam API reaches the game
- **WHEN** a Steam game known to call the Steam API at start (e.g. one that shows the Steam overlay) is launched through the free runner
- **THEN** the game starts, the log shows lsteamclient loaded, and Steam marks the game as running

### Requirement: Game Porting Toolkit detection
The app SHALL detect a Game Porting Toolkit installed by the user and offer it as a runner, and SHALL NOT include any D3DMetal or GPTK file in the repository, a release asset, or a download it hosts.

#### Scenario: GPTK found
- **WHEN** the user has installed the Game Porting Toolkit from Apple's disk image
- **THEN** Runners lists "Game Porting Toolkit" with its version and state ready, copied into Cartouche's runners folder from the user's own install

#### Scenario: Nothing Apple is redistributed
- **WHEN** CI scans the repository and every release asset for D3DMetal or GPTK file names and Apple's library hashes
- **THEN** the scan finds no match and the job passes

#### Scenario: GPTK absent
- **WHEN** no Game Porting Toolkit is installed
- **THEN** Runners shows it as "Not found" with a "How to Get It" link to Apple's page, and D3DMetal is not offered as a backend unless CrossOver provides it
