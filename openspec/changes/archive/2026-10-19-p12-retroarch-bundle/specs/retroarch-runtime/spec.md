## ADDED Requirements

### Requirement: Bundled RetroArch built from source
CI SHALL build RetroArch from the pinned submodule commit, sign it with the Cartouche certificate and embed it in the app, and the repository SHALL contain no RetroArch binary.

#### Scenario: Reproducible build
- **WHEN** the RetroArch CI job runs twice on the same commit
- **THEN** both runs succeed and produce a RetroArch.app whose `--version` output names the pinned commit, embedded under Cartouche.app/Contents/Helpers

#### Scenario: Nothing binary in git
- **WHEN** the repository is scanned for Mach-O files and `.dylib` cores
- **THEN** none belong to RetroArch or libretro cores

### Requirement: Controlled over MCP
Cartouche SHALL start RetroArch with `--mcp-stdio` and its own appended configuration, SHALL drive it only through that pipe, and SHALL never rewrite the user's `retroarch.cfg`.

#### Scenario: Load and query a game
- **WHEN** Cartouche asks the session manager to load a test ROM with a test core
- **THEN** RetroArch shows the game within 5 seconds and `GET_STATUS` over the pipe reports the content as playing

#### Scenario: Clean stop
- **WHEN** Cartouche stops the session
- **THEN** RetroArch writes its auto save state if enabled, exits within 3 seconds, and no RetroArch process remains

#### Scenario: User config untouched
- **WHEN** a user's `retroarch.cfg` exists before Cartouche runs RetroArch ten times
- **THEN** its SHA-256 is unchanged

### Requirement: Cores on demand
Cores SHALL be downloaded only for consoles the user added, from the libretro buildbot for Apple silicon, and SHALL be removable.

#### Scenario: Add a console
- **WHEN** the user adds Super Nintendo
- **THEN** only the recommended core (Snes9x) is downloaded into the cores folder and loads in RetroArch

#### Scenario: Remove a console
- **WHEN** the user removes Super Nintendo
- **THEN** its core file is deleted and no game file is touched

### Requirement: BIOS status
For each console, Cartouche SHALL report which BIOS files its core needs, which are present with the right MD5, and which are missing, and SHALL never offer a BIOS download.

#### Scenario: PlayStation BIOS
- **WHEN** the BIOS folder contains `scph5501.bin` with MD5 490f666e1afb15b7362b406ed1cea246
- **THEN** PlayStation shows the BIOS as found; with the file removed, it shows "scph5501.bin is missing" and the UI contains no download link

### Requirement: Version choice
Settings SHALL let the user run the included RetroArch, an official libretro release, or their own copy, and SHALL say which features need the included build.

#### Scenario: Official release without MCP
- **WHEN** the user picks an official release that lacks the MCP server
- **THEN** games still launch with `-L <core> <file>`, and Continue From and Coach mode show "Needs the included RetroArch"
