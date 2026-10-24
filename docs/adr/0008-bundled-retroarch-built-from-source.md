# 0008. Bundled RetroArch built from source, cores downloaded per console

One accepted decision for Cartouche. Read by contributors and agents who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Console games need an emulator frontend. RetroArch covers most systems and is GPL-3.0, like Cartouche. GitHub releases carry only source; macOS binaries come from the libretro buildbot. RetroArch has an MCP server on `master` (started with `--mcp-stdio`) that is not in stable 1.22.2. Some cores have non-commercial licenses.

## Decision

Cartouche ships its own RetroArch. CI builds it from a pinned commit (submodule, Xcode project in `pkg/apple`), signs it with the Cartouche certificate and embeds it in the app. No binary is committed. Cartouche launches it with `--mcp-stdio` and drives it over stdin and stdout. Cores are never bundled. Each is downloaded from the libretro buildbot when the user adds that console. Settings > Consoles lets the user pick the included RetroArch, an official libretro release, or their own copy. Official releases older than the MCP server fall back to RetroArch's UDP network commands, with limited Time Machine and Coach mode. A Cartouche-owned config is passed with `--appendconfig`, so the user's `retroarch.cfg` is never rewritten. Cartouche never ships or links BIOS or game files.

## Alternatives rejected

- Detect and launch the user's own RetroArch only (older research note). Rejected: the maintainer chose to bundle for a reliable experience.
- Host libretro cores inside Cartouche and render with Metal. Rejected: months of work (audio, input, save states, shaders).
- Use the buildbot binary. Rejected: not built from a pinned source by us.
- Bundle cores. Rejected: some are non-commercial.

## Consequences

- CI builds, signs and tests RetroArch. The build must be pinned and reproducible.
- Cartouche depends on a nightly feature until the next stable RetroArch release.
- GPL-3.0 source obligations apply to the bundled RetroArch.
- `docs/research/retroarch-frontend.md` still has an older section that says Cartouche does not bundle RetroArch. This ADR supersedes it.
