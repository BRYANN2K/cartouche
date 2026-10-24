# Proposal

## Why

Consoles are a core v1 feature. Cartouche plays console games through RetroArch, which it ships, drives and updates itself. RetroArch is GPL-3.0 like Cartouche. Its GitHub releases hold only source tarballs, its macOS binaries live on the libretro buildbot, and its MCP server (`--mcp-stdio`) exists only on `master` today. So Cartouche builds RetroArch from a pinned source commit, signs it, embeds it, and talks to it over MCP.

## What Changes

- RetroArch as a git submodule pinned to a commit that has the MCP server; CI builds it with its Xcode project (`pkg/apple`), signs it with the Cartouche certificate and embeds it in the app.
- A RetroArch session manager: starts RetroArch with `--mcp-stdio` and a Cartouche-owned `--appendconfig`, keeps the pipe, sends commands, reads results, stops it cleanly.
- Core manager: downloads cores per console from the libretro buildbot, verifies them, updates them, deletes them. Cores are never bundled.
- BIOS checker from each core's `.info` file (name and MD5), with no download link.
- Version choice in Settings > Consoles: included build (default), an official libretro release, or the user's own copy; features that need MCP are marked unavailable on builds without it.
- Non-goals: the console library UI (P13), netplay, achievements accounts, translation and Coach mode (P14).
- Depends on P0. Release signing comes from P9; until then CI signs ad hoc.

## Capabilities

### New Capabilities
- `retroarch-runtime`: how Cartouche ships, starts, controls, updates and replaces RetroArch, its cores and BIOS checks.

### Modified Capabilities
- None.

## Impact

`vendor/RetroArch` submodule, a CI job, a new Swift module for the session and core manager, Settings > Consoles. THIRD-PARTY-LICENSES gains RetroArch (GPL-3.0) and the source offer.
