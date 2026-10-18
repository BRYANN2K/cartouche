# 0001. Independent fork of NotProton

One accepted decision for Cartouche. Read by contributors who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Cartouche starts from NotProton (GPL-3.0). NotProton injects code into the Mac Steam client and runs Windows games with CrossOver. Cartouche wants other runners, other stores and a different app. NotProton's contribution policy says other Wine runtimes are not goals.

## Decision

Cartouche is an independent fork. It keeps the GPL-3.0 license and credits NotProton and its authors in README, NOTICE and the About window. It does not follow upstream automatically and sends no pull requests to it. A nightly upstream watch (P9) opens an issue when NotProton, Steam, Wine, DXMT or the Game Porting Toolkit change, and fixes are ported by hand.

## Alternatives rejected

- Contribute to NotProton instead. Rejected: its goals exclude non-CrossOver runners and a library app.
- Track upstream with automatic merges. Rejected: the code diverges too much, and a bad merge could break the Steam-side dylib.
- Start from scratch. Rejected: the Steam hooks, `compat_run.sh`, ntdll patching and tests are years of work.

## Consequences

- Cartouche must keep its own identity so both apps can live on one Mac (P0).
- Steam updates can break the dylib. The team ports fixes from upstream by hand.
- Each new Wine build needs its own ntdll offsets.
- Cartouche states clearly that it is not affiliated with NotProton, Valve, Apple or CodeWeavers.
