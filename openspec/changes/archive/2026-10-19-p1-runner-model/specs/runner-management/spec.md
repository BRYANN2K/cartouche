## ADDED Requirements

### Requirement: Runner registry
The app SHALL keep one registry of runners, each with a source kind, version, supported CPU flavors and state, and every feature SHALL read runners only from this registry.

#### Scenario: CrossOver appears as a runner
- **WHEN** a supported CrossOver build is installed in /Applications and the app refreshes runners
- **THEN** the registry lists one runner of kind CrossOver with its build version, its flavors (Rosetta, plus FEX on macOS 26) and state ready after cloning

#### Scenario: Unsupported build is reported, not used
- **WHEN** a CrossOver build whose hashes are not pinned is found
- **THEN** the registry lists it with state unsupported and the reason, and it is not offered to Steam or to games

### Requirement: Behavior parity with NotProton
Moving CrossOver onto the runner model SHALL NOT change any observable behavior for an existing CrossOver user.

#### Scenario: Existing tests still pass
- **WHEN** the full app test suite runs (`make -s app-tests` and the hermetic C suites listed in the CI workflow)
- **THEN** every test that passed on the P0 baseline still passes, with no test deleted or skipped

#### Scenario: Steam sees the same tools
- **WHEN** Steam lists compatibility tools after the change
- **THEN** the list of CrossOver-based tools is identical to the P0 baseline (names and order)

### Requirement: Damage detection
The app SHALL detect a runner whose files no longer match their pinned hashes and offer to repair it.

#### Scenario: Modified ntdll is caught
- **WHEN** one byte of a cloned runner's ntdll is changed and runners are refreshed
- **THEN** the runner state becomes damaged with the file named, and Repair restores the expected hash
