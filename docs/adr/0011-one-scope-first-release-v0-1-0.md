# 0011. One scope, consoles included, first release v0.1.0

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Planning first split the work into staged releases, with consoles late. The maintainer decided that consoles are a core feature and that a staged public release is not wanted.

## Decision

There is one scope. Everything planned (P0 to P16) is built before the first public release: Steam Play with free runners, Windows installer, compatibility data and estimate, FPS tracking, updates, stores, the MCP server, consoles with bundled RetroArch and their extras, controls, and standalone emulator detection. The first public release is v0.1.0. Later versions follow semver 0.x until the maintainer declares 1.0. The library is designed for PC and Consoles sections from the start (P5).

## Alternatives rejected

- Release a first version with PC games only, consoles later. Rejected by the maintainer.
- Number the first release 1.0. Rejected: 0.x tells users the product is young.

## Consequences

- The first release is large, so the phase order and waves in `docs/ROADMAP.md` matter more.
- `docs/ROADMAP.md` in some branches still shows an older staged split. It must be updated to match.
- Version numbers: 0.1.0 first, then 0.x by semver.
