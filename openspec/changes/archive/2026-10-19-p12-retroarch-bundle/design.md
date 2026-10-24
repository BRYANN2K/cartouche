# Design

## Context

RetroArch `master` has `network/mcp_server.c` and `docs/mcp-server.md` (checked 2026-10-19); 1.22.2 does not. The Apple build lives in `pkg/apple` (Xcode, `GitHubCI.xcconfig`). The buildbot serves cores at `nightly/apple/osx/arm64/latest/<core>_libretro.dylib.zip` and each core has a `.info` file listing extensions and BIOS with MD5.

## Goals / Non-Goals

**Goals:** a RetroArch we can rely on, update and drive.
**Non-Goals:** embedding RetroArch's video inside Cartouche's window; hosting libretro cores in Cartouche.

## Decisions

- **Submodule pinned to a commit, bumped by PR.** Rejected: tracking `master` live (breaks without warning) and the buildbot nightly binary (unsigned by us, not reproducible).
- **MCP over stdio, not UDP network commands.** No port, no token, typed tools, structured results. UDP stays as the fallback for official releases.
- **`--appendconfig cartouche.cfg`** for our settings (paths, menu toggle, MCP). Rejected: editing `retroarch.cfg`, which belongs to the user.
- **Cores from the buildbot, verified by size and a hash recorded at first download, re-checked at each launch.** The buildbot publishes no signatures; we pin what we saw. Rejected: bundling cores (some are non-commercial, e.g. Snes9x, Genesis Plus GX).

## Risks / Trade-offs

- [RetroArch's MCP tool names change on master] → the session manager reads `tools/list` at start and maps by name with tests on the pinned commit; the bump PR runs them.
- [Long Xcode build in CI] → cache derived data; build only when the submodule moves.
- [Buildbot outage] → keep downloaded cores; show "Core download failed, try again later".
