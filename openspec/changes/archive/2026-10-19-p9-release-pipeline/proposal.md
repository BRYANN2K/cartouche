# Proposal

## Why

Releases must be reproducible, signed with a stable identity for free, and reach users through Sparkle and Homebrew without manual steps. The fork also depends on moving parts upstream (NotProton, Steam client, Wine builds, DXMT, GPTK) that can break it at any time.

## What Changes

- CI on every pull request: build, tests, OpenSpec validation, redistribution scan.
- Release on tag: build, sign with the project's self-signed certificate, Sparkle appcast with EdDSA and deltas, GitHub Release, Homebrew tap update.
- Beta and critical update channels.
- A nightly upstream watch that opens an issue when something we depend on changes.
- Non-goals: notarization (decided against), Mac App Store.
- Depends on P0.

## Capabilities

### New Capabilities
- `release-pipeline`: how Cartouche is built, signed, published, updated and kept in step with upstream.

### Modified Capabilities
- None.

## Impact

`.github/workflows/` (ci, release, upstream-watch), a Homebrew tap repository, repository secrets (certificate, Sparkle key). RELEASE and CHANGELOG docs.
