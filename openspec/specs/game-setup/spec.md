# game-setup Specification

## Purpose
How Cartouche picks and applies a graphics backend (D3DMetal, DXMT, DXVK, wined3d) and a Mac or Windows version per game, and keeps Steam's compatibility tool choice in step.

## Requirements

### Requirement: Per-game setup
Each Windows game SHALL have a setup made of a runner, a graphics backend, a CPU translation and optional environment variables, and the launch SHALL apply exactly that setup.

#### Scenario: Backend is applied at launch
- **WHEN** a DirectX 11 test game is set to DXMT and launched
- **THEN** the game's log shows the DXMT d3d11 library loaded and no D3DMetal or DXVK d3d11 library

#### Scenario: Invalid pairs are not offered
- **WHEN** the user opens the Graphics menu for a game on a runner without D3DMetal
- **THEN** D3DMetal is not listed, and FEX is not listed on macOS 15

#### Scenario: Installer games change setup in place
- **WHEN** the user picks a different ready runner or backend for a game installed from a Windows installer
- **THEN** its launcher is rewritten with the same environment a store game would get, in the same prefix, and neither the game nor the prefix is copied

#### Scenario: Older Wine warns but is allowed
- **WHEN** the picked Wine is older than the version that last ran an installer game's prefix
- **THEN** the panel shows a short warning that the prefix was updated by a newer Wine and the game may not start, and the choice is still applied

### Requirement: Steam compatibility tools per setup
The app SHALL register one Steam compatibility tool per valid runner and backend pair, and a change of setup in Cartouche SHALL be reflected in Steam's per-game compatibility choice.

#### Scenario: Tools appear in Steam
- **WHEN** two runners and three backends are ready and Steam is restarted
- **THEN** Steam's Compatibility menu lists every valid pair, named "<runner> · <backend>", and no Cartouche tool clashes with a NotProton tool name

#### Scenario: Cartouche and Steam agree
- **WHEN** the user sets Elden Ring to "Game Porting Toolkit · D3DMetal" in Cartouche
- **THEN** Steam's Properties > Compatibility for Elden Ring shows the same tool, and launching from Steam uses it

### Requirement: Mac or Windows version
For a Steam game that has a native macOS build, the user SHALL be able to choose the Mac version or the Windows version, and the choice SHALL decide which build Steam installs and launches.

#### Scenario: Switch to the Windows version
- **WHEN** the user picks "Windows Version" for a game with a macOS build
- **THEN** Steam is asked to force the chosen compatibility tool, downloads the Windows depot, and the game launches through Wine; the library shows "Windows version"

#### Scenario: Back to the Mac version
- **WHEN** the user picks "Mac Version" again
- **THEN** the forced compatibility tool is cleared, Steam installs the macOS depot, and the game launches natively without Wine

### Requirement: Pinned backends
DXMT and DXVK SHALL be installed only from versions pinned with SHA-256, and D3DMetal SHALL come only from the user's GPTK or CrossOver.

#### Scenario: Backend download is verified
- **WHEN** DXMT is downloaded
- **THEN** its SHA-256 matches the manifest before it is copied into any prefix

### Requirement: Advanced Windows-game options
The Cartouche game panel SHALL expose an Advanced section for all Windows-game sources. Its controls are DLSS→MetalFX, MetalFX upscaling, AVX2 to Rosetta, MSync, High Resolution and Metal HUD, and it SHALL NOT offer frame generation (ADR 0031). Each control SHALL be offered only for a game whose selected runner and graphics backend support it. Runtime mechanisms and per-pair eligibility SHALL be established by research-upscaling before implementation claims or defaults are assigned.

#### Scenario: Windows-game source coverage
- **WHEN** a Windows game from Steam, another store, an installer or an in-place import is selected
- **THEN** its game panel has the same Advanced-section entry point, subject to researched runtime eligibility for each control

#### Scenario: Unsupported runner and backend pair
- **WHEN** a game's selected runner and backend do not support an option
- **THEN** that option is not offered in the game's Advanced section, while it may remain offered for a setup that supports it

#### Scenario: No frame generation
- **WHEN** the Advanced section is shown for any setup
- **THEN** it contains no frame-generation control

#### Scenario: Unresearched option
- **WHEN** an option’s runtime mechanism or eligibility has not been confirmed
- **THEN** no working implementation or universal support is claimed for that option
