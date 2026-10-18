# 0003. Free self-signed signing, no notarization, personal Homebrew tap

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Notarization needs a paid Apple Developer account. Ad-hoc signing gives each build a new identity, so macOS forgets permissions (controllers, folders) and the Keychain asks again for store tokens after each update. Official Homebrew casks refuse apps that are not notarized since 2026-09-01.

## Decision

Cartouche is never notarized. CI creates one self-signed certificate once, keeps it in repository secrets and signs every release with it, so the designated requirement stays the same. Users open the app the first time through System Settings > Open Anyway. Sparkle installs updates without quarantine, so Gatekeeper warns only once. Distribution is by GitHub Releases and a personal Homebrew tap, updated by CI on each release.

## Alternatives rejected

- Paid Apple Developer account and notarization. Rejected: the project must stay free.
- Ad-hoc signing per build. Rejected: permissions and Keychain access reset on every update.
- Official Homebrew cask. Rejected: not possible without notarization.
- Mac App Store. Rejected: needs the paid program and forbids injecting code into Steam.

## Consequences

- The first launch shows a Gatekeeper warning. The README must explain it.
- The certificate private key is a critical secret. If lost, users must reinstall by hand.
- A new Sparkle EdDSA key is generated once in P0. Its private half lives only in CI secrets.
