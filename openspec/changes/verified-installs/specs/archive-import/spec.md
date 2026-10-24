# Archive verification delta

## ADDED Requirements

### Requirement: Archive verification is not installed status
Archive imports SHALL use the installer’s separate installed and verification states. A shipped checksum list or archive CRC SHALL trigger mandatory full verification; when neither exists, script file list and sizes SHALL yield partial verification, or absent evidence SHALL allow “Installed, not verified”. The installer spec’s Stop behavior, mismatch choices, later Verify Files… action, exact helper-hash rules and output-preserving optimization constraints SHALL apply.

#### Scenario: Archive CRC available
- **WHEN** an archive supplies CRC verification without a shipped checksum manifest
- **THEN** the app performs mandatory full verification and does not require a script file list to qualify that CRC evidence

#### Scenario: Archive verification mismatch
- **WHEN** archive output fails the applicable checks
- **THEN** the app shows Retry with the standard method (default), Keep Anyway (advanced), and Cancel, without assigning verified status to mismatched output
