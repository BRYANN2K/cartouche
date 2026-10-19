# release-pipeline Specification

## Purpose
How Cartouche is built, checked, signed with its self-signed certificate, published on GitHub Releases, updated through Sparkle channels and the Homebrew tap, and kept in step with upstream changes.

## Requirements

### Requirement: Pull request checks
Every pull request SHALL build the app, run all test suites, validate OpenSpec changes and scan for redistributed Apple files, and SHALL NOT be mergeable when any check fails.

#### Scenario: Red check blocks merge
- **WHEN** a pull request breaks one unit test
- **THEN** the CI job fails and the branch protection blocks the merge

### Requirement: Stable free signing
Every release SHALL be signed with the same self-signed certificate, so that macOS keeps permissions and Keychain access across updates.

#### Scenario: Identity is stable
- **WHEN** `codesign -d -r-` is run on two consecutive releases
- **THEN** both show the same designated requirement

#### Scenario: Permissions survive an update
- **WHEN** a user grants controller access and stores an Epic token, then updates through Sparkle
- **THEN** the game still sees the controller and no Keychain prompt appears

### Requirement: Updates
Tagging `vX.Y.Z` SHALL publish a GitHub Release with the zip and an EdDSA-signed appcast, and installed copies SHALL offer the update within 24 hours.

#### Scenario: Update offered
- **WHEN** v0.1.1 is published and a Mac runs v0.1.0
- **THEN** the next daily check shows the update with its release notes, installs it, and relaunches into v0.1.1 without a Gatekeeper prompt

#### Scenario: Beta channel
- **WHEN** a beta is published and the user has not opted into Beta
- **THEN** the user is not offered it

### Requirement: Homebrew tap
Each release SHALL update the cask in the project's tap with the new version and SHA-256.

#### Scenario: brew installs the latest
- **WHEN** `brew install --cask <tap>/cartouche` runs after a release
- **THEN** it installs the version just released

### Requirement: Upstream watch
A nightly job SHALL detect new releases of NotProton, the Mac Steam client, CodeWeavers CrossOver source tarballs, WineHQ macOS builds, DXMT and the Game Porting Toolkit, and open one issue per change.

#### Scenario: New Steam client
- **WHEN** Steam publishes a client version not in the supported list
- **THEN** an issue titled "Upstream: Steam client <version>" is opened with the release link, and no duplicate is opened the next night
