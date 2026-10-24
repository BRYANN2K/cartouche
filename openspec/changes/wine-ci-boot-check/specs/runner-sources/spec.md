# Runner sources delta

## MODIFIED Requirements

### Requirement: Pinned free Wine builds
The app SHALL install only Wine builds listed in its runner manifest, and SHALL verify each download against the manifest's SHA-256 before using it.

#### Scenario: Remote manifests are signed
- **WHEN** the app fetches a newer `runners.json` from the compat-data release
- **THEN** it is used only when the detached `runners.json.sig` signature verifies against the EdDSA public key the app ships (SUPublicEDKey); a manifest with a missing or wrong signature is refused and the bundled manifest stays in use

#### Scenario: Install a pinned build
- **WHEN** the user clicks Download on "Cartouche Wine 26.3" in Runners
- **THEN** the archive is downloaded, its SHA-256 matches the manifest, and the runner appears with state ready; after explicit test-prefix initialization has finished successfully, `winecfg` reaches its window within 60 seconds on an M-series Mac (initialization time is measured separately)

#### Scenario: Tampered download is rejected
- **WHEN** the downloaded archive's SHA-256 differs from the manifest
- **THEN** the file is deleted, the runner stays not installed, and the user sees "The download was damaged. Try again."


## ADDED Requirements

### Requirement: Separate Wine CI initialization and window checks
The Wine build CI SHALL run `wineboot -i` with `WINEDLLOVERRIDES=mscoree,mshtml=` for CI initialization only, then `wineserver -w`, under the 20-minute initialization limit `BOOT_INIT_LIMIT`. It SHALL log initialization time and run the existing 60-second winecfg window check only after successful initialization. This CI limit SHALL NOT define the app’s first-boot timeout.

#### Scenario: Successful initialization
- **WHEN** Wine CI initializes a fresh test prefix successfully and the Wine server finishes within BOOT_INIT_LIMIT
- **THEN** CI logs initialization time and starts the separate 60-second winecfg window check

#### Scenario: Initialization fails or exceeds its limit
- **WHEN** prefix initialization fails or the initialization phase exceeds BOOT_INIT_LIMIT
- **THEN** the boot check fails at initialization and does not claim a successful winecfg window check

