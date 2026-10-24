# 0007. Free runners: Wine CrossOver built by our CI, WineHQ builds, user-installed GPTK

One accepted decision for Cartouche. Read by contributors and agents who need to know why.

## Status

Accepted, 2026-10-19.

## Context

Cartouche must run Windows games without a paid CrossOver license. CodeWeavers publishes CrossOver's source under the LGPL (26.3.0 checked on 2026-10-19). Nobody publishes ready macOS builds of it; Gcenx does not. WineHQ publishes official macOS builds. Apple's Game Porting Toolkit (GPTK) carries D3DMetal, and its license does not allow redistribution.

## Decision

Three free runner sources. First, Wine CrossOver built by Cartouche's CI from the pinned CodeWeavers source tarball, published as a release asset with its SHA-256 and the LGPL source offer. Second, official WineHQ macOS builds. Third, a GPTK that the user installs. The app detects it and copies it into `runners/` on the user's Mac only. Cartouche never puts D3DMetal or any GPTK file in the repository, a release or a download it hosts. CI scans for them. D3DMetal comes only from the user's GPTK or an installed CrossOver. Every build is pinned in a manifest with URL, SHA-256 and ntdll offsets. Paid CrossOver stays supported as a runner.

## Alternatives rejected

- Ask users to build Wine themselves. Rejected: too hard.
- Rely on a third party for CrossOver builds. Rejected: none exists and it may stop.
- Resolve ntdll offsets at runtime. Rejected: a wrong offset crashes Steam.
- Bundle GPTK or D3DMetal. Rejected: Apple's license.
- Link GPTK in place. Rejected: Apple updates would change files under Cartouche.
- Runners from wrappers such as Sikarugir engines. Rejected for now.

## Consequences

- CI must build Wine reproducibly: pinned tarball hash, pinned toolchain, cached.
- Each new build needs new ntdll pins (`ntdll-patch/resolve.py`).
- The upstream watch opens an issue when CodeWeavers publishes a new tarball.
- Without GPTK or CrossOver, D3DMetal is not offered, and the app shows how to get GPTK.
- THIRD-PARTY-LICENSES gains Wine notices.
