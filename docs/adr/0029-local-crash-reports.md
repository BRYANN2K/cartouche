# 0029. Crash reports stay local

## Status

Accepted, 2026-10-21. Implementation merged.

## Context

Cartouche has no server and collects no analytics (see `docs/PRIVACY.md`). Crashes still need to be diagnosable by the user and, when the user chooses to share, by the maintainer.

## Decision

Crash reports are generated and kept on the Mac; nothing is sent over the network. After a crash, the next launch prompts with Show Report (the full report) and Copy Summary (a short text the user can paste where they choose). A Collect Diagnostics command builds a zip of logs and reports locally, which the user may share themselves.

## Alternatives rejected

- A crash-reporting endpoint or hosted service.
- Sending reports silently, or on an opt-out basis.

## Consequences

PRIVACY.md lists crash reports and diagnostics bundles as local-only data. Any future remote reporting is a separate opt-in decision and PRIVACY.md must be updated before it is enabled.
