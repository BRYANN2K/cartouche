# P2 free runners: GPTK layout, Wine macOS builds, Gcenx assets

Checked: 2026-10-19 (WebFetch/WebSearch, unauthenticated). Sources older than 12 months are flagged "(old)".

## Question
1. What does a user end up with after installing Apple's Game Porting Toolkit (1.x to 4) and where (dmg names, layout, version marker, license, scan names, public hashes)?
2. Is dl.winehq.org still the place for WineHQ macOS builds, or does WineHQ point to Gcenx?
3. What does Gcenx publish (macOS_Wine_builds assets, sizes, digests, layout; wine-crossover)?
4. Does a 64-bit Wine on macOS still use `wine64` or just `wine`?

## Short answer
- GPTK: user gets an outer `Game_Porting_Toolkit_<v>.dmg` holding `Evaluation environment for Windows games <v>.dmg`; payload is `redist/lib/{external,wine}` (D3DMetal.framework + libd3dshared.dylib under `external`). Version marker inside the files: not confirmed. Apple's license text itself not fetched; Gcenx and a UTM forum post say redistribution is unclear/unpermitted.
- Wine: dl.winehq.org/wine-builds/macosx is stale (2025-04); the practical source is Gcenx `macOS_Wine_builds` (12 releases, latest 11.18; stable only `11.0_1`). `wine-crossover` is gone from Gcenx (404, not confirmed why).
- New wow64 Wine builds ship `wine` only (no `wine64`); GPTK (CrossOver 22.1.1 base, old non-wow64 Wine) still uses `wine64`.

## Findings

### 1. Apple Game Porting Toolkit

Apple page (fetched 2026-10-19): names only "Game Porting Toolkit 4"; no dmg names, no install steps, no license text on the page. Download buttons are search links: `/download/all/?q=game%20porting%20toolkit` and `/download/all/?q=Evaluation%20environment%20for%20Windows%20games`. https://developer.apple.com/games/game-porting-toolkit/
- Apple's repo https://github.com/apple/game-porting-toolkit (fetched 2026-10-19) is Apache-2.0 agent skills, Metal-cpp and samples. README prerequisites: "a Mac with Apple silicon, macOS 27, Xcode 27, and Game Porting Toolkit 4". It does not describe the D3DMetal dmg. Its releases API returns `[]` (see upstream-watch-endpoints.md).
- GPTK 4 dmg names and layout: not confirmed (no source found; one review at https://macsonly.com/article/2026/first-look-game-porting-toolkit-4-beta returned HTTP 429).

**Disk images**
- Outer image for 3.0: `Game_Porting_Toolkit_3.0.dmg`; nested: `Evaluation environment for Windows games 3.0.dmg`. Source: https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0 (undated, 3.0 era, about 2025-26). Volume names there: not listed.
- Mount point confirmed only for 2.1: `/Volumes/Evaluation environment for Windows games 2.1` (https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit, last edited 2025-11-23; and README copy https://gist.github.com/lynkos/3999f629560219a81d4e2c083a4bf5b1, old). Pattern is `Evaluation environment for Windows games <version>`; 2.0 and 3.0 volume names inferred, not confirmed.
- Apple download URL pattern (from MacPorts Portfile): master site `https://download.developer.apple.com/Developer_Tools/Game_Porting_Toolkit_3.0`, distname `Evaluation_environment_for_Windows_games_3.0`. https://raw.githubusercontent.com/macports/macports-ports/master/devel/d3dmetal/Portfile
- MacPorts mirror lists distfile pages: `Game_Porting_Toolkit_1.1.dmg.html` (2024-12-31), `Evaluation_environment_for_Windows_games_2.0.dmg.html` (2025-01-17), `..._2.1.dmg.html` (2025-10-16), `..._3.0.dmg.html` (2025-12-08). https://www.mirrorservice.org/sites/distfiles.macports.org/d3dmetal/ So: 1.1 = `Game_Porting_Toolkit_1.1.dmg`; 2.x/3.x evaluation dmg = `Evaluation_environment_for_Windows_games_<v>.dmg` (underscores in the file name, spaces in the volume name).

**Evaluation environment layout (2.x, 3.x)**
- DMG root: a Read Me, three command-line tools (`gameportingtoolkit*` scripts), and a `lib` folder (for 2.1: "three command-line tools, a Read Me, and a lib folder"; AppleGamingWiki says the scripts are copied to `/usr/local/bin`). https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit
- `redist/lib/external/` holds `D3DMetal.framework` and `libd3dshared.dylib`. Confirmed by AppleGamingWiki (above) and the 2.1 README gist. Pre-built tools are updated by replacing those two items in `<tool>/lib/external/`.
- 3.0: `redist/lib` has two subfolders, `external` and `wine`. `wine/x86_64-unix/nvngx-on-metalfx.so` (rename to `nvngx.so`); `wine/x86_64-windows/nvngx-on-metalfx.dll` (rename to `nvngx.dll`) and `nvapi64.dll`. Source: https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0
- MacPorts 3.0 Portfile: copies `redist/lib` to `${prefix}/libexec/d3dmetal`; docs are `Acknowledgements.rtf`, `License.rtf`, `Read Me.rtf` (so those sit at the DMG root); removes a broken `Headers` symlink in `external/D3DMetal.framework`; removes unneeded `d3d10.so` and `d3d10.dll` stubs (so those exist in the dmg). https://raw.githubusercontent.com/macports/macports-ports/master/devel/d3dmetal/Portfile
- Not confirmed: `atidxx64.dll`, `dxgi.dll`, `d3d11.dll`, `d3d12.dll` as files under `redist/lib/wine/x86_64-windows/`. Only `nvngx*.dll`, `nvapi64.dll`, `d3d10.dll` are named by sources. Check by listing a real dmg.
- Where the version is recorded: not confirmed. AppleGamingWiki says only the Read Me.rtf (and Apple's README.rtf) on the image state it, and that the wiki "doesn't say where the version is stored inside the toolkit files". D3DMetal.framework `Info.plist` CFBundleShortVersionString: not confirmed (search found nothing). The Metal HUD shows "Game Porting Toolkit 3.0" at runtime (mybyways). Safest for code: read `Info.plist` if present, else fall back to the dmg/volume name or Gcenx tag.

**GPTK 1.x via Homebrew**
- Formula `apple/apple/game-porting-toolkit` v1.1, source `crossover-sources-22.1.1.tar.gz`, `depends_on arch: :x86_64`, `--prefix=#{prefix}` (Homebrew keg), test `bin/wine64 --version`, linker rpath `@executable_path/../lib/external`. https://raw.githubusercontent.com/apple/homebrew-apple/main/Formula/game-porting-toolkit.rb (fetched 2026-10-19; only first 100k chars read).
- User then copies the dmg's `redist/lib/` into `$(brew --prefix game-porting-toolkit)/lib/` with `ditto`, and the three scripts to `/usr/local/bin` (AppleGamingWiki, above). The `/usr/local` x86_64 Homebrew location is implied by the `/usr/local/bin` copy and by `depends_on arch: :x86_64`; the exact prefix path: not confirmed. The script names `gameportingtoolkit`, `gameportingtoolkit-no-hud`, `gameportingtoolkit-no-hud-nobuild`-style: exact names not confirmed (AppleGamingWiki says "three gameportingtoolkit* scripts").
- Build failures on Sonoma reported (old): https://developer.apple.com/forums/thread/748129

**Gcenx cask `gcenx/wine/game-porting-toolkit` (current)**
- `version "3.0-3"`, `sha256 "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e"`, url `https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-#{version}/game-porting-toolkit-#{version}.tar.xz`. https://raw.githubusercontent.com/Gcenx/homebrew-wine/master/Casks/game-porting-toolkit.rb
- `app "Game Porting Toolkit.app"`; binaries `#{appdir}/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64`, `.../wine64-preloader`, `.../wineserver`. Postflight: `xattr -drs com.apple.quarantine`, then `codesign --force --deep -s -`. Conflicts with wine-crossover, wine-stable, wine@devel, wine@staging casks. Requires Rosetta.
- `lib/external/D3DMetal.framework` inside that app: path `Game Porting Toolkit.app/Contents/Resources/wine/lib/external/` is implied by the Apple README ("Game Porting Toolkit.app ... `lib/external/`") but not directly confirmed.
- Gcenx note: "The provided archive contains Game porting toolkit, please ensure you comply with Apple's License.pdf for D3DMetal." Wine sources are from `apple/homebrew-apple@2bc4428`. Requirements: Apple Silicon, macOS 14+, bundles GStreamer.framework v1.28.1. https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3
- Gcenx tags/assets (API, 2026-10-19): `Game-Porting-Toolkit-3.0-3` (2026-03-03) `game-porting-toolkit-3.0-3.tar.xz` 239200808 bytes sha256 `d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e`; `-3.0-2` (2026-02-13) 260757848 bytes `c16b3b40b9a34853fc1f4546d13d20d28bc06e0f2edcfcf425df2ef7f2ec4ba4`; `-3.0-1` (2026-02-13) 260771456 bytes `e56931ca4f029d48136b09dda12ca1aadacb993d62d18c9e31192a0bb7eebb80`. https://api.github.com/repos/Gcenx/game-porting-toolkit/releases?per_page=3
- Other Gcenx tags seen on the releases page: 3.0, 2.1, 1.1, `1.1-gstreamer`, 3.0 beta 3/4/5. https://github.com/Gcenx/game-porting-toolkit/releases
- Other common places for the swap: Whisky and CrossOver (`CrossOver.app/Contents/SharedSupport/CrossOver/apple_gptk` holds `external` and `wine`; CrossOver 26.0 ships D3DMetal 3.0 itself, per mybyways).

**License**
- Apple's License.pdf / License.rtf text: not fetched (not publicly reachable without the dmg). Secondary: license grants limited right to install, internally use and test "for the sole purpose of" evaluating games (secondary article, summarised in search; not confirmed against the original).
- Apple developer forum, Aug 2026: "CrossOvers and Whisky both redistribute D3DMetal in their app. We would like to do so as well but the included license does not make it clear." 0 replies. https://developer.apple.com/forums/thread/841547 So redistribution is not clearly permitted. Treat as forbidden unless Apple answers.
- MacPorts lists license as "Restrictive" and its port cannot download the file ("get it from the Apple Developer site"). https://ports.macports.org/port/d3dmetal/details/

**Names a redistribution scan should catch** (confirmed in sources): `D3DMetal.framework`, `libd3dshared.dylib`, `nvngx-on-metalfx.dll`, `nvngx-on-metalfx.so`, `nvngx.dll`, `nvngx.so`, `nvapi64.dll`, `apple_gptk` (CrossOver folder), `Game Porting Toolkit.app`. Not confirmed as Apple-only: `d3d10.dll`, `d3d10.so` (named in MacPorts Portfile as stubs).

**Public SHA-256 values**
- Apple `Evaluation_environment_for_Windows_games_3.0.dmg`: sha256 `d49395fb07e536804d1da0858590e53f6aa6fab12512e18fd80a74c87f9f063c`, size 25006010 bytes (MacPorts Portfile, link above; rmd160 `e262284bef5c6a0819325386ed3f2a0aa32c0a6c`).
- Gcenx GPTK tarballs: see digests above (these are Gcenx archives containing D3DMetal, not Apple dmgs).
- Apple 1.1, 2.0, 2.1, 4 dmg hashes: none found. SHA-256 of the D3DMetal binary itself: none found.

### 2. WineHQ macOS builds
- https://dl.winehq.org/wine-builds/macosx/ today lists only `pool/` and `download.html` (modified 2025-04-23); older than 12 months, stale (fetched 2026-10-19).
- https://wiki.winehq.org/MacOS redirects (301) to https://gitlab.winehq.org/wine/wine/-/wikis/MacOS, which returned an Anubis "Access Denied" page, so its text was not read. https://www.winehq.org/download returned 403. Quote of WineHQ pointing to Gcenx: not confirmed.
- Evidence of WineHQ endorsement (secondary): Bugzilla 57091, Zeb Figura: "the Mac builds are official, built by Dean Greer" (Gcenx). https://bugs.winehq.org/show_bug.cgi?id=57091 (closed 2025-02-07, older than 12 months by a few months).
- The Gcenx repo title is "Official Winehq macOS Packages" (search result title for https://github.com/Gcenx/macOS_Wine_builds).
- Caution: Homebrew casks `wine-stable`, `wine@devel`, `wine@staging` now have `disable! date: "2026-09-01", because: :fails_gatekeeper_check`. The tarball URLs still work. https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/w/wine-stable.rb. Implication: an app launcher must remove quarantine (`xattr`) or download without quarantine itself; not confirmed that the tarballs are unsigned/un-notarized.

### 3. Gcenx macOS Wine builds
`GET https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=100` (2026-10-19) returned 12 releases total (page 2 was `[]`). Asset names `wine-<channel>-<tag>-osx64.tar.xz`; size in bytes; digest is sha256 (GitHub returns `"digest": "sha256:..."`).

| tag | published | asset | size | sha256 |
|---|---|---|---|---|
| 11.18 | 2026-09-25 | wine-devel-11.18-osx64.tar.xz | 190974384 | aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82 |
| 11.18 | 2026-09-25 | wine-staging-11.18-osx64.tar.xz | 193105336 | b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127 |
| 11.17 | 2026-09-11 | wine-devel-11.17-osx64.tar.xz | 191290556 | c2b3a8274dbc594deaa64e40469b607cbc4aa8ef5656dec4c5f6f3dac0da770c |
| 11.17 | 2026-09-11 | wine-staging-11.17-osx64.tar.xz | 193354896 | aff31fb4ce1a2d769d7c4525664331cad70a8c3a92b587a374f82517532069e2 |
| 11.16 | 2026-08-24 | wine-devel-11.16-osx64.tar.xz | 191440520 | 6f9af818b7af6001aeed7818cb32bf0155598c5ea4e3b33380a03cf814e033cd |
| 11.16 | 2026-08-24 | wine-staging-11.16-osx64.tar.xz | 193568360 | cd68f230c773a761b8a0423a08c51fbe49e89b6e52246f3866898d259a4988c6 |
| 11.0_1 | 2026-04-16 | wine-stable-11.0_1-osx64.tar.xz | 185303032 | b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388 |

Other releases (devel and staging pairs, same pattern): 11.15 (2026-08-08), 11.14 (2026-07-27), 11.13 (2026-07-17), 11.10 (2026-06-04), 11.9 (2026-05-17), 11.8 (2026-05-02), 11.7 (2026-04-18; devel 320111712 bytes, staging 189397976), 11.6_1 (2026-04-16; devel 319775820, staging 322511424).
- A `wine-stable-*-osx64.tar.xz` exists, but only one: `wine-stable-11.0_1-osx64.tar.xz` in tag `11.0_1`. It is not in the newest tags, so `releases/latest` will not give stable; filter assets by prefix `wine-stable-`.
- Tag formats: `11.18` (major.minor) and `11.0_1`, `11.6_1` (rebuild suffix `_N`). Homebrew's wine@staging uses `version.major_minor` as the tag, so a `_N` version maps to the tag without suffix there; careful when mapping.
- Archive top-level layout (from Homebrew casks, which unpack these tarballs): `Wine Stable.app`, `Wine Devel.app`, `Wine Staging.app`. Inside: `Contents/Resources/wine/bin/wine` (also `wineserver`, `wineboot`, `winecfg`, `msiexec`, `regedit`, `regsvr32`, `notepad`...) and `Contents/Resources/start/bin/{appdb,winehelp}`. Sources: wine-stable.rb (link above), https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/w/wine@devel.rb and `.../wine@staging.rb` (both at version 11.16 when fetched, so Homebrew lags 11.18).
- Gcenx README (https://github.com/Gcenx/macOS_Wine_builds): "move the `Wine *` bundle to `/Applications`"; packages `wine-stable`, `wine@devel`, `wine@staging`; needs GStreamer.framework per search summary (not verified on the README itself).
- `wine-crossover`: https://raw.githubusercontent.com/Gcenx/homebrew-wine/master/Casks/wine-crossover.rb returned 404. `https://api.github.com/repos/Gcenx/homebrew-wine/contents/Casks` lists only `game-porting-toolkit.rb`. https://github.com/Gcenx/winecx and `repos/Gcenx/winecx/releases` returned 404; `repos/Gcenx/wine-on-mac/releases` returned `[]`. Conclusion: Gcenx no longer publishes CrossOver-source Wine builds in these places. Version and removal date: not confirmed.
- Old CrossOver-based engines only: Sikarugir Engines lists WineCX19.0.2, 20.0.4, 21.2.0, 23.7.1 as "provided but won't receive support" (dated 2024-10, old). https://github.com/Sikarugir-App/Engines/releases
- CodeWeavers publishes CrossOver source itself (26.3.0 per upstream-watch-endpoints.md); building it is the only alternative.

### 4. `wine64` versus `wine`
- New wow64 builds ship no `wine64`; one `wine` loader handles 32 and 64-bit. Bugzilla 57091 (Wine 9.15 Gcenx builds): Zeb Figura, "new wow64 builds don't ship wine64." Closed INVALID 2025-02-07 (older than 12 months). https://bugs.winehq.org/show_bug.cgi?id=57091
- Homebrew casks for the 11.x Gcenx builds link only `.../wine/bin/wine` (no `wine64`). Fetched 2026-10-19 from wine-stable.rb, wine@devel.rb, wine@staging.rb.
- Exception: Gcenx's GPTK app (old CrossOver 22.1.1 based, non-wow64) still exposes `wine64`, `wine64-preloader`, `wineserver`.
- Rule for code: prefer `bin/wine`; if the runner is a GPTK app or a Wine older than 9.x wow64 builds, fall back to `bin/wine64`. In which exact Wine version Gcenx switched to wow64: not confirmed (9.15 builds were already wow64).

## Open points
- WineHQ wiki/download text (Anubis/403 blocked WebFetch). Needs a browser read to quote the line about macOS builds.
- GPTK 4: dmg names, volume names, layout, license text not found. Needs a real download.
- D3DMetal.framework Info.plist version key: not confirmed.
- Whether `atidxx64.dll`, `dxgi.dll`, `d3d11.dll`, `d3d12.dll` exist under `redist/lib/wine/x86_64-windows/`: not confirmed.
- Exact `gameportingtoolkit*` script names and the 1.x keg prefix path: not confirmed.
- Apple SHA-256 for GPTK 1.1/2.0/2.1/4 dmgs: not found (3.0 evaluation dmg only).
- Gcenx wine-crossover removal: reason and last version not confirmed.
- Whether the Gcenx Wine tarballs are signed/notarized (cask disabled for Gatekeeper on 2026-09-01).

## Sources
- https://developer.apple.com/games/game-porting-toolkit/ (2026-10-19)
- https://github.com/apple/game-porting-toolkit (2026-10-19)
- https://developer.apple.com/forums/thread/841547 (2026-10-19; thread Aug 2026)
- https://developer.apple.com/forums/thread/748129 (search result only, old)
- https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit (2026-10-19; page edited 2025-11-23)
- https://gist.github.com/lynkos/3999f629560219a81d4e2c083a4bf5b1 (2026-10-19; GPTK 2.1 README copy, old)
- https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0 (2026-10-19)
- https://www.mirrorservice.org/sites/distfiles.macports.org/d3dmetal/ (2026-10-19)
- https://raw.githubusercontent.com/macports/macports-ports/master/devel/d3dmetal/Portfile (2026-10-19)
- https://ports.macports.org/port/d3dmetal/details/ (2026-10-19)
- https://raw.githubusercontent.com/apple/homebrew-apple/main/Formula/game-porting-toolkit.rb (2026-10-19)
- https://raw.githubusercontent.com/Gcenx/homebrew-wine/master/Casks/game-porting-toolkit.rb (2026-10-19)
- https://api.github.com/repos/Gcenx/homebrew-wine/contents/Casks (2026-10-19)
- https://github.com/Gcenx/game-porting-toolkit/releases and /releases/tag/Game-Porting-Toolkit-3.0-3 (2026-10-19)
- https://api.github.com/repos/Gcenx/game-porting-toolkit/releases?per_page=3 (2026-10-19)
- https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases?per_page=15 and ?per_page=100 (2026-10-19)
- https://github.com/Gcenx/macOS_Wine_builds and raw README.md (2026-10-19)
- https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/w/wine-stable.rb, wine@devel.rb, wine@staging.rb (2026-10-19)
- https://dl.winehq.org/wine-builds/macosx/ (2026-10-19; content 2025-04)
- https://wiki.winehq.org/MacOS -> https://gitlab.winehq.org/wine/wine/-/wikis/MacOS (Anubis blocked, 2026-10-19)
- https://bugs.winehq.org/show_bug.cgi?id=57091 (2026-10-19; closed 2025-02-07)
- https://github.com/Sikarugir-App/Engines/releases (2026-10-19; content 2024-2025)
- https://api.github.com/repos/Gcenx/winecx/releases (404), https://api.github.com/repos/Gcenx/wine-on-mac/releases (`[]`) (2026-10-19)
