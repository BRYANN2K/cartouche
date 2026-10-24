# Open questions: D3DMetal toggles, GPTK and CrossOver 26 Wine, macos-15-intel wineboot, Steam WebUI transport auth

Phase: post-P9 investigation. Researched 2026-10-22. Every source below is dated 2025-2026 unless flagged. "Not confirmed" means only a forum post, an issue, or a single secondary source supports the claim.

---

## Q1. DLSS to MetalFX with D3DMetal, and other D3DMetal toggles

**Question:** Which variables or registry keys turn DLSS into MetalFX under D3DMetal, how other launchers expose it, what nvngx/nvapi64 is needed, and which other toggles they expose.

**Short answer:** `D3DM_ENABLE_METALFX=1` (Apple's GPTK Read Me, off by default, macOS 26+). It only works when GPTK's `nvngx-on-metalfx.{dll,so}` is installed as `nvngx`, and `nvngx.dll` plus `nvapi64.dll` are in the prefix's `windows/system32`. Heroic's PR also sets an NGXCore registry path. The other documented toggles are `D3DM_SUPPORT_DXR`, `D3DM_MTL4`, `D3DM_MAX_FPS`, `ROSETTA_ADVERTISE_AVX`, `MTL_HUD_ENABLED`, `WINEMSYNC`, and `WINEESYNC`.

**Findings**
- Apple's GPTK 4.0b3 Read Me, as paraphrased in pufflet issue #28 (2026-10-18), lists these controls:
  - `D3DM_SUPPORT_DXR`: off on M1/M2, on for M3+.
  - `D3DM_ENABLE_METALFX`: off; documented for macOS 26; "converts supported DLSS calls to MetalFX".
  - `D3DM_MTL4`: on for macOS 27+; opting out selects Metal 3.
  - `D3DM_MAX_FPS`: a numeric cap, unset by default.
  - `ROSETTA_ADVERTISE_AVX`: off; macOS 15+.
  - `D3DM_DXIL_PROCESS_DEBUG_INFORMATION=1` together with `MTL_CAPTURE_ENABLED=1`: debug only.
  - The issue warns against undocumented `D3DM_*` variables. https://github.com/talhabalaj/pufflet/issues/28
- Apple's procedure, as copied by the lynkos guide (post dated 2025-03-19, later updated; GPTK 3.0, "macOS 16 [=26]"):
  - Rename `wine/x86_64-unix/nvngx-on-metalfx.so` to `nvngx.so`.
  - Rename `wine/x86_64-windows/nvngx-on-metalfx.dll` to `nvngx.dll`.
  - Copy `nvngx.dll` and `nvapi64.dll` into `$WINEPREFIX/drive_c/windows/system32`.
  - Set `D3DM_ENABLE_METALFX=1`.
  - Source: https://github.com/lynkos/blog/blob/main/_posts/2025-03-19-play-windows-games.md
  - So D3DMetal ships its own nvngx (inside GPTK's `redist/lib/wine/...`), not in `external/`.
- webmonarch/crossover-dx12-fix (verified 2026-08-23) applies the same nvngx steps on top of GPTK 4.0b2. It reports that the bridge does not engage there, because D3DMetal reports "AMD Compatibility Mode" (DeviceId 0x66af), which NGX rejects. FSR and XeSS work. https://github.com/webmonarch/crossover-dx12-fix
- Heroic PR #5984 (opened 2026-10-18, **open, not merged**) adds a per-game "DLSS via MetalFX" setting (`enableMetalFX`). The PR text says it:
  - swaps in `nvngx-on-metalfx.dll`;
  - copies `nvngx.dll` and `nvapi64.dll` into the prefix;
  - sets `HKLM\Software\NVIDIA Corporation\Global\NGXCore\FullPath`;
  - sets `D3DM_ENABLE_METALFX=1`, or `DXMT_ENABLE_NVEXT=1` on DXMT builds;
  - patches `gdi32.dll` for frame generation.
  - The author tested it on GPTK 3.0. I could not read the diff, so the exact paths are not confirmed. https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/pull/5984
- Heroic `main`, `src/backend/launcher.ts` (`setupWineEnvVars`), has no `D3DM_*` variables. It sets:
  - `MTL_HUD_ENABLED=1` (showFps on a Mac);
  - `WINEMSYNC=1` (enableMsync or a `-DXMT` runner);
  - `WINEESYNC=1` (toolkit runners);
  - `ROSETTA_ADVERTISE_AVX=1` (advertiseAvxForRosetta and a toolkit runner).
  - Source: https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/main/src/backend/launcher.ts
- Whisky upstream, `WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift` (`environmentVariables`). The repo is archived, so this code is older than 12 months.
  - Sets `MTL_HUD_ENABLED=1`, `METAL_CAPTURE_ENABLED=1`, `ROSETTA_ADVERTISE_AVX=1`, `D3DM_SUPPORT_DXR=1`, `WINEESYNC=1`, and `WINEMSYNC=1`.
  - MSync also sets `WINEESYNC=1`, because "D3DM detects ESYNC".
  - No MetalFX setting. https://github.com/Whisky-App/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift
- frankea/Whisky (active fork, 3.7.0), same file:
  - `D3DM_ENABLE_METALFX=1` (metalFX setting) and `D3DM_MTL4=1` (metal4Enabled).
  - `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` for frame generation. The code comment says Streamline refuses DLSS-FG otherwise.
  - `WINED3DMETAL=0` for wined3d, and `MTL_DEBUG_LAYER=1`.
  - DLL placement happens in `Wine.applyMetalFX`, which seeds a system32 placeholder and an NGX model config under `drive_c/ProgramData/NVIDIA/NGX/models`. It deliberately does not deploy the payload's nvapi64/nvngx.
  - Sources: https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift and https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift
- CrossOver 26 has a built-in DLSS toggle ("DLSS powered by MetalFX", D3DMetal and DXMT only, requires DLSS on in the game). Known only through a search snippet of CodeWeavers' "Advanced Settings in CrossOver Mac 26" page, which could not be fetched; not confirmed. https://codeweavers.helpjuice.com/en_US/advanced-settings-in-crossover-mac-26
- GPTK-Patcher-Tool (Sept 2026 audit) writes `D3DM_ENABLE_METALFX=1` and `DXMT_ENABLE_NVEXT=1` into `CrossOver.app/.../etc/CrossOver.conf`. A bottle's `cxbottle.conf` overrides that. https://github.com/macprotips/GPTK-Patcher-Tool
- diacunap/wine-cx-sikarugir (undated) adds `D3DM_VENDOR_ID=0x10de` and `D3DM_DEVICE_ID=0x2684` (an NVIDIA GPU ID spoof) and `D3DMETAL=1`. These are not in Apple's documented list, so they are **not confirmed**. https://github.com/diacunap/wine-cx-sikarugir
- Version support: MetalFX conversion first appears with GPTK 3.0 / D3DMetal 3 on macOS 26 (lynkos, Heroic PR) and is still documented in 4.0b3 (pufflet #28). No source shows it in GPTK 2.x.

**Open points:** The exact `NGXCore\FullPath` value. Whether D3DMetal 4's "AMD Compatibility Mode" adapter blocks NGX for all titles or only some (one report).

**Recommendation for Cartouche:**
- Expose a "DLSS via MetalFX" toggle that does three things together:
  - set `D3DM_ENABLE_METALFX=1`;
  - place `nvngx.dll` (from GPTK's `nvngx-on-metalfx.dll`, same GPTK version as `external/`) and `nvapi64.dll` in the prefix's system32, with the matching `nvngx.so` in the unix DLL path;
  - keep `nvapi64=n;nvngx=b`.
- Only allow the toggle on macOS 26+, and label it experimental.
- Keep `WINEESYNC=1` alongside MSync, as Whisky does.

---

## Q2. GPTK 3.x/4.x with Wine built from CrossOver 26.x sources

**Question:** Is D3DMetal from GPTK 3/4 compatible with CrossOver 26.x's shims, how do other projects wire it in, and what is known about Unity DX11 crashes?

**Short answer:** D3DMetal is a matched set: `external/` (D3DMetal.framework + libd3dshared.dylib) and `wine/` (Apple's d3d11/d3d12/dxgi PE DLLs and .so files). Every project that works swaps both from the same GPTK. Swapping only `external/` is reported to page-fault. Cartouche reads only `lib/external` (`PortingToolkitSource.swift:172`), so a mismatch between that and its own d3d shims is the most likely cause of the CarX Street crash (my inference, not confirmed).

**Findings**
- Apple's own CrossOver procedure, quoted by crossover-dx12-fix: `cd .../CrossOver/lib64/apple_gptk; mv external external.old; mv wine wine.old; ditto <GPTK>/redist/lib/ .`. Tested with CrossOver 26.3.0.39832; the page says 26.3 (2026-07-21) still ships D3DMetal 3.0. GPTK 4 adds `d3d10` and drops `atidxx64`. https://github.com/webmonarch/crossover-dx12-fix
- Endfield_FineWine #53 (2026-10-16), Unity title, CrossOver Preview with D3DMetal 4.0b2:
  - Replacing only `redist/lib/external` crashed with a "page fault in `_D3D12GetInterface+0x54`".
  - Also installing 4.0b3's `redist/lib/wine/x86_64-windows` fixed the launcher.
  - GPTK 4 + D3DMetal then hung in `UnityPlayer.dll` (WaitForMultipleObjectsEx). `CX_GRAPHICS_BACKEND=dxmt` worked.
  - Source: https://github.com/stoicswe/Endfield_FineWine/issues/53
- Sikarugir #222 (2026-05) shows how the files link:
  - GPTK's `wine/x86_64-unix/{dxgi,d3d11,d3d12}.so` load `@rpath/libd3dshared.dylib`.
  - libd3dshared resolves `@rpath/D3DMetal.framework` through `@loader_path`, so it only works next to its framework.
  - Gcenx: "Sikarugir already sets all needed env itself"; Apple does not test D3DMetal on old macOS patch releases.
  - Source: https://github.com/Sikarugir-App/Sikarugir/issues/222
- `CX_APPLEGPTK_LIBD3DSHARED_PATH` is used even when D3DMetal is off:
  - CrossOver's `bin/wine` always exports it. ntdll uses it in `dlls/ntdll/unix/loader.c` (CW HACK 22434) to register PE modules as Rosetta non-native code regions (Endfield #38, 2026-10-12; not checked against the tarball). https://github.com/stoicswe/Endfield_FineWine/issues/38
  - NotProton PR #63 (merged 2026-10-08) sets it to fix a Metaphor crash on CrossOver 26.3. https://github.com/NotProtonNot/NotProton/pull/63
  - So pointing it at GPTK 4's libd3dshared changes ntdll behaviour too.
- How others place D3DMetal:
  - GPTK-Patcher-Tool replaces the whole `apple_gptk` folder (`lib64/apple_gptk` on CX 25/26, `lib/apple_gptk` on Preview 27). It supports GPTK 2.1 to 4.0 but was only tested with 4.0b2 on CX 26.2/26.3/27. It notes `CX_GRAPHICS_BACKEND_VERSION=3` selects `lib/apple_gptk3`. https://github.com/macprotips/GPTK-Patcher-Tool
  - Pufflet (`GameGraphics.swift` per #28) sets `WINEDLLOVERRIDES=d3d10,d3d11,d3d12,dxgi=b`, `WINEDLLPATH_D3DMETAL`, and `WINEDLLPATH_PREPEND`. https://github.com/talhabalaj/pufflet/issues/28
  - wine-cx-sikarugir patches ntdll to read `WINEDLLPATH_D3DMETAL`/`_DXMT`/`_DXVK` first. It also notes CrossOver's closed `cxcompatdb.so` (CW Hack 24067) puts wined3d first. https://github.com/diacunap/wine-cx-sikarugir
- Known working combinations:
  - CX 26.x stock = D3DMetal 3.0 (crossover-dx12-fix).
  - CX 26.3 + full GPTK 4.0b2 swap: works for UE 5.6 DX12 (same source).
  - No source confirms an `external/`-only 4.0b3 swap on CX 26.
- Unity DX11 under D3DMetal:
  - An itch.io report says Unity 6 still creates D3D12 internally despite `-force-d3d11` / `-force-d3d11-no-singlethreaded` and dies on a missing fence feature under CrossOver. Single forum post, **not confirmed**. https://itch.io/post/15344879
  - The common workaround is DXMT (Endfield #53).

**Open points:** Not verified against the CX 26.3 tarball: whether its open-source d3d11/dxgi call libd3dshared themselves when `CX_GRAPHICS_BACKEND=d3dmetal`. Whether libd3dshared 4.0b3 is safe for CW HACK 22434 under 26.3's ntdll.

**Recommendation for Cartouche:**
- Import GPTK's whole `redist/lib` tree (`external/` plus `wine/x86_64-windows` and `wine/x86_64-unix`) from one GPTK version, keeping the sibling layout.
- Point `CX_APPLEGPTK_LIBD3DSHARED_PATH` at that copy's `external/libd3dshared.dylib`.
- Prepend its `wine/` dirs to WINEDLLPATH with `d3d10,d3d11,d3d12,dxgi=b` (add `d3d12core` for 4.x).
- Never mix one GPTK version's `external/` with another source's shims.
- Use DXMT as the default for Unity DX11 games.

---

## Q3. macos-15-intel: first wineboot hangs, then kernel32.dll c0000135

**Question:** Is there a known runner issue where Wine's first wineboot hangs ("run_wineboot boot event wait timed out", then "could not load kernel32.dll, status c0000135"), and what are the workarounds?

**Short answer:** No runner-images issue names Wine. The closest match is a `macos-15` CI hang caused by wineboot waiting on the Wine Mono install prompt (no `~/.cache/wine` on runners). The fix was `WINEDLLOVERRIDES=mscoree,mshtml=` or pre-seeding Mono, plus a short timeout. macos-13 runners are gone (fully unsupported 2025-12-04), so they are not a fallback.

**Findings**
- Wine `dlls/ntdll/unix/env.c` `run_wineboot` waits up to 5 minutes. On timeout it logs "boot event wait timed out" and **continues** with a half-initialised prefix, which explains the later c0000135. https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/unix/env.c
- Benehiko/protium PR #13 (merged 2026-10-01), `macos-15` runner:
  - The hang was `wineboot --init` starting `control.exe appwiz.cpl install_mono` with nobody to answer it.
  - Fix: `WINEDLLOVERRIDES=mscoree,mshtml=` (later PR #14 fetches Mono instead), a 10-minute step limit, and a diagnostics dump (wine processes, login session).
  - Source: https://github.com/Benehiko/protium/pull/13
- runner-images #12725 (closed 2025-10-06, older than 12 months): macos-15 GUI-session hangs depended on the provisioner because of a TCC/Bluetooth prompt. Images were fixed. https://github.com/actions/runner-images/issues/12725
- runner-images #13358 (closed 2025-12-15, older than 12 months): `PerfPowerServices` used 100% CPU on macos-15-intel. Image fix rolled out. https://github.com/actions/runner-images/issues/13358
- runner-images #13045: macos-15-intel is available until August 2027. #13046: macos-13 fully unsupported by 2025-12-04. https://github.com/actions/runner-images/issues/13045 , https://github.com/actions/runner-images/issues/13046
- Cartouche's `boot-check.sh` is given 60 s (`.github/workflows/wine-crossover.yml:102`). Wine's own wait is 300 s, so the check can fail before wineboot does. Not a Wine fault by itself.

**Open points:** No public report ties macos-15-intel image versions to Wine specifically. Untested: whether the CrossOver-built ntdll/loader needs environment that CrossOver's `bin/wine` wrapper normally sets (CX_ROOT etc.).

**Recommendation for Cartouche:**
- In the boot check, set `WINEDLLOVERRIDES=mscoree,mshtml=`, `WINEDEBUG=+loaddll,err` and `DISPLAY`-free headless options.
- Allow at least 330 s.
- On failure, dump `ps` and the prefix's `system32` listing.
- Use self-hosted Intel (or `vars.WINE_RUNNER`) only if it still hangs.

---

## Q4. Steam macOS client WebUI routes: transport authentication

**Question:** How do Steam injection projects authenticate or limit access to custom routes or JS bridges, and are per-route flags irrelevant once the websocket is authenticated?

**Short answer:** No public reverse-engineering of `CWebUITransport` auth was found. Millennium and its peers use CEF remote debugging (CDP) on a randomised port, not Steam's WebUI transport. Per-route flags are not irrelevant: the client serves `TransportAuth.Authenticate#1` before any key exists, so the flags decide which routes need the key. Treat this as Cartouche's own finding, not public knowledge.

**Findings**
- Millennium:
  - Relies on Steam's CEF remote debugging. The port is randomised unless `-dev` (release v2.31.0). https://newreleases.io/project/github/SteamClientHomebrew/Millennium/release/v2.31.0
  - The docs say it "uses the debugging channel" to talk to the client, with backend calls through `callable`. https://docs.steambrew.app/about
  - No token scheme is documented.
- CDP has no authentication: anything that reaches the loopback port can run JS in the Steam UI (Nova-Deck os-build #99, third-party). https://github.com/Nova-Deck/os-build/issues/99
- Steam session-hijack malware abuses `-cef-enable-debugging` (secondary, **not confirmed**). https://malwaretips.com/threads/steam-session-hijacking-malware-via-mitm-proxy-and-cef-debugger-abuse.142938/
- Steam also checks the connecting process: "WebUITransport: Connection rejected" until the client is steamwebhelper or its child (dean-plude/os PR #292, 2026-10-10). https://github.com/dean-plude/os/pull/292
- DarkNavy describes the privileged `SteamClient` object injected only into steampowered.com / steamloopback.host pages. The page could not be fetched; known only from a search snippet. https://www.darknavy.org/blog/exploiting_steam_usual_and_unusual_ways_in_the_cef_framework/
- Repo context:
  - `SteamClient.WebUITransport.GetTransportInfo()` returns `portClientdll` and `authKeyClientdll`; the socket is `ws://localhost:<port>/transportsocket/` (`dylib/feats/webpatch.c:449-451`).
  - Cartouche copies the access flags of the `TransportValidation*` routes and never copies those of `TransportAuth.Authenticate#1` (`dylib/feats/webui.c:28-42`).
  - No public source contradicts or confirms this model.

**Open points:**
- Whether the flags also bind a route to one transport (SteamUI vs clientdll, each with its own key).
- Whether an authenticated socket can call a route flagged for the other transport.
- Both need a test against the shipped client.

**Recommendation for Cartouche:**
- Keep copying flags from an authenticated `TransportValidation*` route; per-route flags matter.
- Add a test that calls a Cartouche route on an unauthenticated socket and expects a rejection.
- Do not rely on CDP/remote debugging for bridges.

---

## Sources
- https://github.com/talhabalaj/pufflet/issues/28 (2026-10-18)
- https://github.com/lynkos/blog/blob/main/_posts/2025-03-19-play-windows-games.md (2025-03, older than 12 months, updated for GPTK 3)
- https://github.com/webmonarch/crossover-dx12-fix (verified 2026-08-23)
- https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/pull/5984 (2026-10-18, open)
- https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/blob/main/src/backend/launcher.ts (main, read 2026-10-22)
- https://github.com/Whisky-App/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift (archived, older than 12 months)
- https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift , .../Wine/Wine.swift (read 2026-10-22)
- https://github.com/macprotips/GPTK-Patcher-Tool (Sept 2026 audit)
- https://github.com/diacunap/wine-cx-sikarugir (undated)
- https://github.com/stoicswe/Endfield_FineWine/issues/53 (2026-10-16), /issues/38 (2026-10-12)
- https://github.com/NotProtonNot/NotProton/pull/63 (merged 2026-10-08)
- https://github.com/Sikarugir-App/Sikarugir/issues/222 (2026-05-10)
- https://itch.io/post/15344879 (undated forum post)
- https://codeweavers.helpjuice.com/en_US/advanced-settings-in-crossover-mac-26 (search snippet only)
- https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/unix/env.c (master)
- https://github.com/Benehiko/protium/pull/13 (2026-10-01)
- https://github.com/actions/runner-images/issues/12725 (2025), /13358 (2025), /13045, /13046
- https://newreleases.io/project/github/SteamClientHomebrew/Millennium/release/v2.31.0 ; https://docs.steambrew.app/about
- https://github.com/Nova-Deck/os-build/issues/99 ; https://github.com/dean-plude/os/pull/292 (2026-10-10)
- https://www.darknavy.org/blog/exploiting_steam_usual_and_unusual_ways_in_the_cef_framework/ (snippet only)

---


## Q5. OutputVerification components

The partial check (`GameVerify.checkSizes`) reads the installer script's file list from
`innoextract --list-sizes --silent`. That output is `<bytes> <path>` only: no language, component
or task per file. What the pinned innoextract (1.10-dev-2025-01-07 + 6e9e34e, `src/cli/extract.cpp`)
can tell us:

- **Languages: handled.** `--language-only` lists only the files tied to a language (any language
  when `--language` is not given). `InnoInspector.markingLanguageFiles` runs it once more and marks
  those paths; `GameVerify.installedFiles` makes them optional like multi-listed variants (absent
  passes, present must match a listed size). The non-silent `--list` also prints ` [lang]` after a
  file, but with human-rounded sizes, so it is not used.
- **Components and tasks: not exposed.** `file_entry.components` / `tasks` are parsed but never
  printed. The only trace is the `#component` suffix `--collisions=rename-all` adds to paths that
  collide, i.e. files already listed more than once (already optional as variants). `--info`
  prints components only in DEBUG builds. So a file listed once and installed only with an
  unchosen component or task is still reported missing.
- We cannot tell from the CLI whether an installer declares components or tasks at all, so the
  "only flag missing files when the installer declares none" rule cannot be applied without
  dropping missing-file detection for every Inno install. It is not applied.

Way out: we already build innoextract from a pinned source plus one patch
(`installer/innoextract/pins`). A small patch that appends the file's `components`/`tasks`
expressions to `--list-sizes` lines (or a new `--list-filters` flag) would let `installedFiles`
mark those files optional too, and record the chosen components if the install log
(`unins000.dat`) is read later.
