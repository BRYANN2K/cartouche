# P3 graphics backends: research

Checked 2026-10-19. Limits: this run had no shell, so no archive was downloaded. SHA-256 values come from the GitHub API `digest` field. Archive inner paths are NOT verified.

## Question
DXMT, DXVK-macOS, CrossOver backend variable, Steam appinfo and Steam compat-tool config, for Cartouche P3.

## Short answer
- DXMT latest is v0.80 (2026-04-23), confirmed. One asset, "builtin" build. License is changing MIT to LGPL after v0.80.
- DXVK-macOS (Gcenx) is stale (last release 2024-07, DXVK 1.10.3, zlib). Upstream DXVK is v3.1.1 (zlib).
- CX_GRAPHICS_BACKEND values and the Steam config.vdf write-back are NOT confirmed by a primary source.

## 1. DXMT
- Releases, API checked 2026-10-19 ([API](https://api.github.com/repos/3Shain/dxmt/releases?per_page=3)):
  - v0.80, 2026-04-23: `dxmt-v0.80-builtin.tar.gz`, 18681669 bytes, sha256 `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`.
  - v0.74, 2026-03-10: `dxmt-v0.74-builtin.tar.gz`, 18990005 bytes, sha256 `2598981a8b725653773e277470a95dda4253b8a14d36e0dc96dce0e3800f0ceb`.
  - v0.73, 2026-01-21: `dxmt-v0.73-builtin.tar.gz`, 19022981 bytes, sha256 `c9f06fc8b52c80f146e4b964605a4ac91beef1dbc35d113e305c4185a5c036ca`.
- v0.80 has exactly 1 asset ([release API](https://api.github.com/repos/3Shain/dxmt/releases/tags/v0.80)). Release page says "Assets 3", which counts the two source archives ([release page](https://github.com/3Shain/dxmt/releases/tag/v0.80)).
- Release notes: v0.81 (bug fixes) and v1.0 are planned. Notes carry no install steps.
- License at tag v0.80: `LICENSE` is the MIT License text, "Copyright (c) 2023 Feifan He" (checked by the implementer, https://raw.githubusercontent.com/3Shain/dxmt/v0.80/LICENSE). On the default branch, `LICENSE` is GNU LGPL 2.1 or later text. GitHub API shows `NOASSERTION` ("Other"), so the SPDX id is not auto-detected. Likely `LGPL-2.1-or-later` (our reading of the text) ([license API](https://api.github.com/repos/3Shain/dxmt/license)).
- Release body: "changing the license of DXMT from MIT to LGPL"; "v0.80 will be the last release distributed in MIT license" ([release page](https://github.com/3Shain/dxmt/releases/tag/v0.80)). So v0.80 itself is MIT, later releases LGPL.
- Install guide ([wiki: DXMT Installation Guide for Geeks](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks), fetched via summarizer, 2026-10-19):
  - Wine needs: FOSS CrossOver Wine 24+ built from source is enough. Self-built Wine: source >= Wine 8, with the API in DXMT's `winemacdrv.h` exposed from `winemac.drv` (symbols hidden by default). So a stock Wine does not work.
  - Option A (build with `-Dwine_builtin_dll=true`, which the release tarball `-builtin` and CI artifact use):
    - `winemetal.so` to `<wine>/lib/wine/x86_64-unix/`.
    - `winemetal.dll` to `<wine>/lib/wine/x86_64-windows/` and `<prefix>/drive_c/windows/system32/`.
    - `d3d11.dll`, `dxgi.dll`, optional `d3d10core.dll` to `<wine>/lib/wine/x86_64-windows/`.
    - DLL overrides must NOT be `native,builtin`.
    - CrossOver 25+: files can replace those in `CrossOver.app/Contents/SharedSupport/CrossOver/lib/dxmt`. Guide warns not to open CodeWeavers tickets after doing so.
  - Option B (default build, non-builtin): `d3d11.dll`, `dxgi.dll`, `d3d10core.dll` go to `<prefix>/drive_c/windows/system32/`; set `WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=n,b;"`. `winemetal` placed as in A.
- Archive inner paths of `dxmt-v0.80-builtin.tar.gz`: NOT confirmed (not downloaded). The guide's layout implies `x86_64-windows` and `x86_64-unix` folders. Verify with `tar -tzf` in an empty temp dir.
- README is minimal; no i386 mention found ([README](https://raw.githubusercontent.com/3Shain/dxmt/main/README.md)). 32-bit support: not confirmed.

## 2. DXVK for macOS
- Gcenx/DXVK-macOS ([API](https://api.github.com/repos/Gcenx/DXVK-macOS/releases?per_page=3)); a fork of doitsujin/dxvk ([repo](https://github.com/Gcenx/DXVK-macOS)):
  - Latest `v1.10.3-20230507-repack`, 2024-07-23 (older than 12 months, stale):
    - `dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz`, 2785833 bytes, sha256 `810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00`.
    - `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`, 2793443 bytes, digest null (not computed).
  - Previous: `v1.10.3-20230507` (2023-05-07, 7077450 bytes, digest null); `v1.10.3-20230402` (2023-04-02) with a `-CrossOver` variant (9395238 bytes) and a plain one (7675520 bytes).
  - README install: `x64/*.dll` to `system32`, `x32/*.dll` to `syswow64`, then `d3d11` and `d3d10core` overrides. Archive inner layout otherwise not confirmed. No MoltenVK mention in README.
  - License: `LICENSE`, SPDX `Zlib` ([license API](https://api.github.com/repos/Gcenx/DXVK-macOS/license)).
- Upstream doitsujin/dxvk: `v3.1.1`, 2026-09-15; assets `dxvk-3.1.1.tar.gz`, `dxvk-native-3.1.1-steamrt-sniper.tar.gz` ([API](https://api.github.com/repos/doitsujin/dxvk/releases/latest)). License `Zlib` ([API](https://api.github.com/repos/doitsujin/dxvk/license)).
- Upstream README does not mention MoltenVK or macOS ([README](https://raw.githubusercontent.com/doitsujin/dxvk/master/README.md)). It mentions `VK_EXT_graphics_pipeline_library`. Whether 2.x/3.x runs on MoltenVK: not confirmed here (the claim in the task is not sourced).
- Which build macOS Wine users use: only the Gcenx 1.10.3 line is evidenced. CrossOver's patched DXVK: not confirmed. CrossOver 26 lists DXVK as a backend ([docs](https://codeweavers.helpjuice.com/en_US/advanced-settings-in-crossover-mac-26)).

## 3. CrossOver
- CrossOver 26 Advanced Settings lists: Auto, DXMT, D3DMetal, DXVK, Wine (wined3d). Each manual choice applies to all apps in the bottle. Auto "picks a backend for each game from CrossOver's internal database"; if none listed, wined3d. No per-DirectX-version breakdown on the page ([CodeWeavers docs](https://codeweavers.helpjuice.com/en_US/advanced-settings-in-crossover-mac-26), fetched 2026-10-19).
- `CX_GRAPHICS_BACKEND`: only seen as `"CX_GRAPHICS_BACKEND" = ""` under `[EnvironmentVariables]` in `cxbottle.conf` in a community post ([mybyways blog](https://mail.mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0/), date not shown). Accepted values: NOT confirmed. Source tarball was not inspected (no shell). Likely values mirror the GUI, but that is a guess.
- Bundled backends: DXMT dir `CrossOver.app/Contents/SharedSupport/CrossOver/lib/dxmt` (CrossOver 25+, from DXMT wiki above). `apple_gptk` sits in the same SharedSupport/CrossOver folder (blog above). `lib/dxvk` path: not confirmed.
- CrossOver 26 ships D3DMetal 3.0, vkd3d 1.18, DXMT v0.72 (secondary: [LinuxAdictos](https://en.linuxadictos.com/Crossover-26-raises-the-bar-for-Windows-games-on-Mac-and-Linux.html)).

## 4. Steam appinfo and depots
- Example live data, app 413150: `common/oslist` = `windows,macos,linux`; `common/osarch` = ""; `common/osextended` = `macos64`. Depots carry `config/oslist`: 413151 `windows`, 413152 `macos`, 413153 `linux`; shared depots 229002/229012 `windows` ([steamcmd.net API](https://api.steamcmd.net/v1/info/413150), 2026-10-19). Launch entries also carry `config/oslist`.
- Valve doc: OS support is set per app and via one depot per OS; no oslist detail ([Steamworks platforms](https://partner.steamgames.com/doc/store/application/platforms)).
- Forced compat tool with a native build (Linux), forum/news only, no Valve doc: ticking the option makes Steam download the Windows version; unticking restores Linux files ([GamingOnLinux, 2019-01](https://www.gamingonlinux.com/2019/01/another-steam-client-beta-is-out-adds-the-ability-to-force-steam-play/comment_id=146073), older than 12 months). Choosing a Steam Linux Runtime entry instead pulls the Linux depot ([Steam forum, Dwarf Fortress](https://steamcommunity.com/app/975370/discussions/0/3949154954319857046)). Exact depot-selection rule: not confirmed.

## 5. Steam config
- Path `config/config.vdf` > InstallConfigStore > Software > Valve > Steam > CompatToolMapping > `<appid>` { name, config, priority }. Key `"0"` is the global default ([tinkergame wiki](https://github.com/360900/tinkergame/wiki/Steam-Compatibility-Tool)). `name` must be the tool's internal name; a wrong name made Steam fall back silently ([NixOS commit](https://git.sigkill.computer/titaniumtown/nixos/src/commit/774d748bfebd23800d42dcb1f79954b648dac1d7)).
- Priority: 250 appears in a third-party skill guide for per-app entries ([skill](https://skillsmp.com/creators/fx/cc/plugins-steam-skills-steam-linux)); 75 appears in the tinkergame wiki for key "0". Meaning of the values: not confirmed by Valve. Capitalization differs between sources (`Priority` vs `priority`).
- Write-back on exit: only a generic tip "close Steam before editing, Steam may overwrite" ([same skill](https://skillsmp.com/creators/fx/cc/plugins-steam-skills-steam-linux)). Not confirmed by a primary source. Safe design: edit only with Steam closed.

## Open points
- Run `tar -tzf` on the DXMT v0.80 tarball and the Gcenx archive in an empty temp dir; compute SHA-256 for Gcenx assets with null digest.
- Grep `crossover-sources-26.3.0.tar.gz` for `CX_GRAPHICS_BACKEND` (needs a shell).
- Find a sourced answer on DXVK 2.x/3.x on MoltenVK.
- The DXMT license after v0.80 (LGPL): confirm SPDX when a later release is pinned. v0.80 is MIT (checked).
