# 0012. Install script to avoid the Gatekeeper warning

What this decision is and why. For the maintainer and contributors.

- Status: Accepted, 2026-10-19
- Amends: 0003 (free self-signed signing)

## Context

Cartouche is signed with a free self-signed certificate and is not notarized (ADR 0003). Apps downloaded by a browser get the `com.apple.quarantine` attribute, so macOS shows "Not Opened" and the user must click Open Anyway in System Settings. Notarization would remove this but needs a paid Apple Developer membership. On 2026-10-19 we checked that a file downloaded with `curl` has no `com.apple.quarantine` attribute (only `com.apple.provenance`), so Gatekeeper does not show the warning for it.

## Decision

The recommended install is a one-line script: `curl -fsSL <repo>/install.sh | sh`. It downloads the release zip with curl, checks the SHA-256 published with the release and the code signature, installs to /Applications and opens the app. The dmg and the Homebrew tap stay available, with the Open Anyway steps.

## Alternatives rejected

- Paid notarization: costs money every year (rejected by the maintainer).
- Telling users to run `xattr -dr com.apple.quarantine`: works but asks users to type a security-looking command by hand.
- Homebrew `--no-quarantine`: removed by Homebrew 5.

## Consequences

- No warning for users of the script, and no warning on updates (Sparkle).
- Users must trust a shell script: it stays short, readable and pinned in the repository, and verifies what it installs.
- To verify on clean macOS 15 and 26 accounts in P18; if a future macOS adds quarantine to curl downloads, the script falls back to explaining Open Anyway.
