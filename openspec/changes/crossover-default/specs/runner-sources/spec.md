# Runner sources delta

## ADDED Requirements

### Requirement: Published Cartouche Wine default
The app SHALL pin the published `wine-crossover-26.3.0-1-x86_64.tar.xz` asset from `BRYANN2K/cartouche-wine` in its runner manifest with size `149444708` bytes and SHA-256 `60400817826a053599193aa290d4e24e97213a743195f4187400bf9c74906887`. New games SHALL default to this Cartouche Wine runner. Existing explicit per-game runner choices SHALL remain unchanged.

#### Scenario: Published build is offered
- **WHEN** the app offers its default free runner for a new game
- **THEN** it selects Cartouche Wine and uses the published release URL, size and SHA-256 above for any required download

#### Scenario: Existing choice is preserved
- **WHEN** a game already has an explicit runner choice and the new default becomes available
- **THEN** that game retains its runner choice

### Requirement: Explain unavailable Graphics choices
The Graphics menu SHALL list only offered backends and SHALL hide unavailable backends. Neither the panel nor menu SHALL show unavailable-backend reason lines. One Get More Graphics Backends… entry SHALL appear only when something is missing and SHALL lead to installing Cartouche Wine. D3DMetal eligibility still requires CrossOver-capable Wine, Rosetta and user-supplied D3DMetal files; DXMT requires CrossOver and its download. Apple files SHALL NOT be redistributed.

#### Scenario: Missing Cartouche Wine
- **WHEN** Cartouche Wine is missing and a backend cannot be offered
- **THEN** that backend is hidden, no reason line is shown, and one Get More Graphics Backends… entry leads to installing Cartouche Wine

#### Scenario: Missing GPTK files
- **WHEN** D3DMetal cannot be offered because the user’s D3DMetal files are unavailable
- **THEN** D3DMetal is hidden without a panel/menu reason line and one Get More Graphics Backends… entry is available

#### Scenario: All backends offered
- **WHEN** all graphics backends are offered
- **THEN** the menu contains no Get More Graphics Backends… entry

#### Scenario: Onboarding runner choice
- **WHEN** onboarding presents the initial runner choice
- **THEN** Cartouche Wine is preselected

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

## MODIFIED Requirements

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
- **THEN** Runners shows it as "Not found" with a "How to Get It" link to Apple’s page, and the default Cartouche Wine runner’s Graphics menu explains that D3DMetal needs the user’s GPTK files
