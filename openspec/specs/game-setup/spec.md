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
