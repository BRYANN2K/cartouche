# Verified installation delta

## ADDED Requirements

### Requirement: Verified output before installed status
The app SHALL separate installed and verification states: full (mandatory shipped checksum or archive CRC), partial (script presence/sizes; “verified (sizes)”), or unavailable (“Installed, not verified” with a discreet badge and panel line). It SHALL NOT offer a skip checkbox. Process success or executable presence alone SHALL NOT imply verification. Stop during verification SHALL mark not verified.

#### Scenario: Shipped checksum manifest
- **WHEN** installation output has a shipped checksum manifest
- **THEN** the app always verifies against it before assigning a fully verified status, with no skip option

#### Scenario: Archive CRC
- **WHEN** archive CRC is available without a shipped checksum list
- **THEN** the app always verifies archive integrity as full verification, without requiring an installer script file list for that level

#### Scenario: Partial evidence only
- **WHEN** no checksum is available but the installer script supplies a file list and sizes
- **THEN** the app checks presence and sizes and labels passing output “verified (sizes)”, not fully verified

#### Scenario: No verification evidence
- **WHEN** the installer supplies neither checksum/CRC evidence nor a usable file list and sizes
- **THEN** installation is allowed with “Installed, not verified”, a discreet badge and a game-panel line

#### Scenario: Stop verification
- **WHEN** the user presses Stop during verification
- **THEN** verification stops and the game is marked not verified

### Requirement: Ordered verification fallback
On verification failure or mismatch the app SHALL show “Some files don’t match” with Retry with the standard method as the default action, Keep Anyway as an advanced action, and Cancel. Retry SHALL start fallback with shipped helpers and original settings. If that path fails, guided execution of the real installer under Wine SHALL be the last resort. Every result SHALL retain the appropriate verification level; no fallback exit alone implies verified output.

#### Scenario: Optimized extraction mismatch
- **WHEN** an optimized extraction fails verification
- **THEN** the failure sheet offers the three actions and defaults to Retry with the standard method, which starts the shipped-helper/original-settings retry when chosen

#### Scenario: Keep mismatched output
- **WHEN** the user chooses Keep Anyway
- **THEN** the game is marked not verified and mismatched files are listed in the log

#### Scenario: Cancel after mismatch
- **WHEN** the user chooses Cancel in the mismatch sheet
- **THEN** no retry starts and the output is not marked verified

#### Scenario: Original-helper retry fails
- **WHEN** the original-helper retry fails
- **THEN** the user is offered a guided real-installer run under Wine as last resort and its result receives the applicable verification status

### Requirement: Verify files later
The game menu SHALL offer Verify Files… for later verification, including when the user supplies a checksum list. Later verification SHALL apply the same mandatory evidence checks and failure choices.

#### Scenario: Checksum list supplied later
- **WHEN** the user supplies a checksum list and chooses Verify Files… for a not-verified game
- **THEN** the files are checked against it and verified status is granted only on success

### Requirement: Output-preserving optimizations
Optimizations SHALL change speed only, not output. Native helper replacements SHALL be selected only for exact helper versions matched by a hash allowlist; unknown versions SHALL use the shipped Windows helpers. Each optimization SHALL produce byte-identical output on the local regression corpus, including the user-owned CarX Street, Lost in Random and Silksong RAR cases where applicable. Corpus files and verification data SHALL never leave the Mac.

#### Scenario: Unknown helper hash
- **WHEN** a helper version is not an exact hash-allowlist match
- **THEN** the native replacement is not used and the shipped Windows helper is used instead

#### Scenario: Regression comparison
- **WHEN** an optimization is proposed for supported helper versions
- **THEN** its output is compared byte-for-byte with the original path on applicable local corpus cases and any output difference blocks acceptance of that optimization

#### Scenario: Local corpus only
- **WHEN** regression verification runs
- **THEN** corpus files and verification data remain on the Mac and are not uploaded

