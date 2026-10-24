# Design

## Context

NotProton patches ntdll at hard-coded RVAs found with `ntdll-patch/resolve.py`, per CrossOver build. CodeWeavers publishes CrossOver source tarballs (`media.codeweavers.com/pub/crossover/source/`, 26.3.0 checked on 2026-10-19) under the LGPL. Nobody publishes ready-made macOS builds of them today, so we build them. Our build's ntdll differs from CodeWeavers' binaries and needs its own pins.

## Goals / Non-Goals

**Goals:** two free runners with the same Steam integration as CrossOver.
**Non-Goals:** supporting any Wine build that is not pinned.

## Decisions

- **Pin, don't discover.** Each supported build gets a manifest entry (URL, SHA-256, ntdll hashes, RVAs). Rejected: resolving offsets at runtime, which turns a wrong offset into a crash inside Steam.
- **Copy GPTK into the runners folder on the user's Mac only.** Same approach NotProton uses for CrossOver. Rejected: linking in place, because Apple's updates would change files under us.
- **Manifest shipped with the app and refreshed with the compatibility data (P4).** New builds can be pinned without an app update.

## Risks / Trade-offs

- **Build in our CI, reproducibly.** Pinned source tarball hash, pinned toolchain, output published as a Cartouche release asset with its SHA-256 and the LGPL source offer. Rejected: asking users to build, or relying on a third party that may stop.
- [The build is long or breaks on a new Xcode] → cache the toolchain, keep the last good runner live; the upstream watch (P9) opens an issue when CodeWeavers publishes a new source tarball.
- [GPTK license changes] → the detection only reads the user's copy; nothing to retract from releases.

## Implementation notes (checked 2026-10-19)

Facts the code relies on, with sources. Details in `docs/research/free-runner-sources.md`.

- **CodeWeavers tarball.** `crossover-sources-26.3.0.tar.gz` at `media.codeweavers.com/pub/crossover/source/`: HTTP 200, 149054023 bytes, Last-Modified 2026-07-21, SHA-256 `ac99c8ca…dd6872` (downloaded and hashed). It holds `sources/wine` (`VERSION`: Wine 11.0) and `sources/{dxvk,moltenvk,vkd3d,freetype,gnutls,gstreamer,glib,…}`. No prebuilt binary besides one test `autorun.exe` in glib. MSync is in the open sources (`sources/wine/server/msync.c`, `dlls/ntdll/unix/msync.c`). `winemac.drv` carries the open D3DMetal glue (`d3dmetal.c`), not D3DMetal itself.
- **Install layout.** Wine's `makedep` installs the loader in `$(libdir)/wine/<arch>-unix/wine` and a `bin/wine` link, which is CrossOver's own layout, so the run script and ntdll patcher can use our build without a new layout.
- **WineHQ builds.** `dl.winehq.org/wine-builds/macosx/` is stale (2025-04). The official macOS builds are Gcenx's (`github.com/Gcenx/macOS_Wine_builds`). Pinned from the GitHub API digest: `wine-stable-11.0_1-osx64.tar.xz` (185303032 bytes, `b50dc50e…cb82388`) and `wine-devel-11.18-osx64.tar.xz` (190974384 bytes, `aa0ea4c8…7ba6f82`). Their root is `Wine Stable.app/Contents/Resources/wine` and `Wine Devel.app/Contents/Resources/wine` (first tar entries read). New wow64 builds ship `bin/wine`, no `wine64`.
- **GPTK.** Apple's evaluation image holds `redist/lib/external/{D3DMetal.framework,libd3dshared.dylib}` and `redist/lib/wine/x86_64-windows/*.dll`. On a 4.0b3 copy, the version is `CFBundleShortVersionString` in `D3DMetal.framework/Versions/A/Resources/Info.plist`, and the `x86_64-unix/*.so` files are links to `libd3dshared.dylib`. CrossOver's own D3DMetal path (`lib64/apple_gptk`) is not confirmed on a real CrossOver.
- **CI runner.** `macos-15-intel` is the x86_64 image in `actions/runner-images` (Xcode 16.4 default). llvm-mingw `20261006` pinned by its GitHub digest.

Choices the specs left open, taken conservatively:

- Free runners are listed by the registry but not offered to Steam until their ntdll is pinned (`Runner.build` stays nil). Rejected: offering them with CrossOver's tool list, which would change the P1 baseline and hook unpinned offsets.
- The registry adds free runners only when given a `FreeRunnerScan`, so the CrossOver Status pane and P1's tests see what they saw. Rejected: adding them to every refresh.
- A refreshed manifest is accepted only when valid, newer, https on github.com, and it keeps every pin the app already has. Rejected: trusting any newer copy, since nothing signs it.
- Damage on free runners is checked against hashes taken at install time (a receipt), not against hashes in the manifest, because the archive's inner files are not known before CI builds it.
