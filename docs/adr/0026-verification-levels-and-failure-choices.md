# 0026. Verification levels and explicit failure choices

## Status

Accepted, 2026-10-21. Supersedes ADR 0025 in part: installed-status gating, evidence levels and failure interaction. Its output-preserving optimization and local-corpus rules stand. Implementation is pending.

## Context

Not every installer exposes checksums or a file list. Users need an honest verification status without blocking all such installations. A mismatch needs an explicit recovery choice.

## Decision

Use three verification levels:

1. Full: a shipped MD5/checksum list or archive CRC is available. Always verify; there is no skip option. Stop during verification marks the game not verified.
2. Partial: no checksum exists, but the installer script supplies a file list and sizes. Check presence and sizes. On success show “verified (sizes)”.
3. Unavailable: no usable verification evidence, for example NSIS/MSI under Wine without a file list. Allow installation and show “Installed, not verified” with a discreet badge and a game-panel line.

Provide Verify Files… in the game menu for later verification, including when the user supplies a checksum list. Do not offer a skip-verification checkbox.

On failure show “Some files don’t match” with Retry with the standard method (default), Keep Anyway (advanced), and Cancel. Retry starts the shipped-helper/original-settings fallback from ADR 0025, with guided real-installer execution under Wine as the last resort. Keep Anyway records not verified and lists mismatched files in the log. Cancel must not claim verified output.

## Alternatives rejected

- Refuse every installation without checksum evidence.
- Label presence-and-size checks as full verification.
- Silently keep mismatched output or retry without showing the failure choices.
- Add a skip-verification checkbox.

## Consequences

Keep installed state separate from verification state. Missing evidence, stopped verification and Keep Anyway must not acquire a verified label. Archive CRC alone qualifies as full evidence under this amendment; ADR 0025’s extra file-list requirement no longer applies when CRC is available. Optimization hash allowlists, byte-identical regression checks and keeping the corpus local remain unchanged. The detection tree remains proposed.
