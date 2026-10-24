# Bonus feature research: emulators on macOS (Apple silicon)

Date: 2026-10-18. Author: research subagent.

## Question

Which game and system emulators (and frontends) run on macOS today, what is their real status, and which one should Cartouche support first for each system?

## Short answer

- **~95 entries** are listed below (standalone emulators, frontends and key libretro cores). Most systems up to PS2/GameCube/3DS/Switch have an active native arm64 option.
- Best-supported today: Dolphin, PCSX2, DuckStation, PPSSPP, Azahar, Flycast, RetroArch (all arm64/universal and active). Weak spots: **Xbox 360 (none), PS4 (alpha), PS3 (experimental), Wii U (Rosetta only)**.
- Licence trap for bundling: DuckStation is CC-BY-NC-ND (no redistribution of modified builds, no commercial use). Snes9x is non-commercial. Cartouche should **detect and launch**, not bundle.

Legend: "nc" = not confirmed from a primary source (knowledge or secondary only). "[n]" = Sources number. Version/date = latest GitHub/Gitea/GitLab release API or Homebrew data read on 2026-10-18. "Casks flagged *disabled*" were disabled in Homebrew on 2026-09-01 for `fails_gatekeeper_check` (unsigned or not notarized builds): `brew install` will not work, use the official download and handle quarantine/Gatekeeper.

Important Homebrew trap: cask `cemu` is **CEmu (TI calculator)**, NOT Cemu (Wii U) [62].

---

## 1. Multi-system emulators and frontends

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS | CLI launch |
|---|---|---|---|---|---|---|---|---|
| RetroArch | Frontend for libretro cores (all systems) | Universal/arm64 (cask `retroarch` = OpenGL, `retroarch-metal` = Metal) | OpenGL, Metal, Vulkan/MoltenVK (nc) | GPL-3.0 | Active; v1.22.2, 2025-11-20 (slow stable cadence, commits daily) [1] | `brew install --cask retroarch-metal` (also `retroarch`, `retroarch-metal@nightly`); buildbot.libretro.com | Per core | `retroarch -L <core>.dylib <rom>`; `-f` fullscreen; `--menu` |
| OpenEmu | Multi-system frontend with bundled cores (NES, SNES, GB/GBA, Genesis, Saturn, PS1, N64, etc.) | Universal (nc; 2.4.x targets Apple silicon) | Metal/OpenGL (nc) | BSD-2 for app, cores GPL/various (nc) | Slow/stalled; v2.4.1, 2023-12-30, repo pushed 2025-10-22 [2] | Cask `openemu` is *disabled*; download from openemu.org | Per core | No documented CLI (nc); `open -a OpenEmu <rom>` works (nc) |
| ares | NES, SNES, N64, GB/GBC/GBA, Mega Drive/CD/32X, SMS/GG, PCE, PS1, Saturn, WonderSwan, NGP, MSX, ColecoVision, Neo Geo | Universal | Metal-less; OpenGL via ruby (nc) | ISC [3] | Active; v148, 2026-05-30 [3] | `brew install --cask ares-emulator` | Some (Saturn, MCD, PS1) | `ares <rom>`; options `--system`, `--fullscreen`, `--no-file-prompt` (nc) |
| MAME | Arcade + hundreds of computers/consoles | arm64 (formula bottle) | OpenGL / bgfx-Metal | GPL-2.0+ and BSD-3 (mixed) [4] | Active; mame0289, 2026-07-30 (monthly) [4] | `brew install mame` | ROM sets/BIOS per driver | `mame <driver> [-cart <rom>] [-rompath <dir>] [-window]` |
| Mednafen | NES, SNES, GB/GBA, Lynx, NGP, PCE, PC-FX, VB, SMS/GG/MD, Saturn, PS1, WonderSwan | arm64 (formula) | OpenGL/SDL | GPL-2.0+ | Slow; 1.32.1, 2024-04-05 [5] | `brew install mednafen` | PS1, Saturn, PC-FX, PCE-CD | `mednafen <file>`; `-force_module <name>` |
| ES-DE (EmulationStation Desktop Edition) | Frontend (~150 systems), launches external emulators | Universal/arm64 (nc) | OpenGL | MIT | Active; v3.5.0, 2026-09-30 [6] | `brew install --cask es-de`; es-de.org | None | `es-de --help`; launches via `es_systems.xml` command templates |
| Pegasus Frontend | Frontend, launches external emulators, themeable | Universal/arm64 (nc) | Qt/OpenGL | GPL-3.0 (+ asset limits) [7] | Slow; weekly_2024w38 (2024-10-05); `continuous` pre-release 2026-09-15 [7] | pegasus-fe.github.io | None | `pegasus-fe [--fullscreen]` (nc) |
| Lakka | RetroArch distro | **No macOS** (Linux only) | n/a | GPL | Active | n/a | n/a | n/a |
| Gearboy / Gearsystem / Gearcoleco / Geargrafx / Gearlynx (drhelius) | GB/GBC; SMS/GG/SG-1000; ColecoVision; PCE/SGX; Lynx | arm64 + Intel zips | OpenGL | GPL-3.0 | Active; 3.8.18 / 3.9.22 / 1.7.4 / 1.8.4 / 1.2.35, 2026-10-11..15 [36] | cask `gearboy`; others GitHub zips | Lynx boot ROM, PCE-CD | `gearboy <rom>` (nc) |
| SkyEmu | GB/GBC/GBA/DS (partly) | macOS dmg (arch nc) | Metal/OpenGL (nc) | MIT | Active; v5, 2026-02-12 [37] | GitHub dmg | None | `SkyEmu <rom>` (nc) |
| BizHawk | Multi-system TAS | **No macOS** | n/a | MIT | Active (Windows/Linux) | n/a | n/a | n/a |
| UTM / QEMU (see Computers) | Generic VM | | | | | | | |

### Key libretro cores that matter on macOS

Cores ship via RetroArch's Online Updater (macOS arm64). Repo activity checked via GitHub API on 2026-10-18 [61].

| Core | Systems | Apple silicon | Graphics | License | Status | Install | BIOS | CLI |
|---|---|---|---|---|---|---|---|---|
| Genesis Plus GX | SMS, GG, Genesis/MD, Sega CD, SG-1000 | arm64 | n/a (RA video) | Non-commercial custom (nc) | Active (repo pushed 2026-10-16) | RA updater | Sega CD BIOS | `retroarch -L genesis_plus_gx_libretro.dylib rom` |
| PicoDrive | Genesis, 32X, Sega CD | arm64 | RA | GPL-2 (nc) | Active (nc) | RA updater | 32X/CD BIOS | same pattern |
| Mupen64Plus-Next | N64 | arm64 | OpenGL (GLideN64) | GPL-2.0 | Active (2026-10-01) | RA updater | None | same |
| Beetle PSX / PCSX ReARMed / SwanStation | PS1 | arm64 | SW/GL; SwanStation (DuckStation fork) | GPL-2.0 / GPL-3.0 | Active (2026-10-18 / 10-01 / 10-15) | RA updater | PS1 BIOS | same |
| Beetle Saturn / Kronos / Yabause cores | Saturn | arm64 (nc for Beetle Saturn: needs fast CPU) | RA | GPL | Active (Kronos core; Yabause core pushed 2026-09-01) | RA updater | Saturn BIOS (optional for some) | same |
| Flycast | Dreamcast/Naomi/Atomiswave | arm64 | GL | GPL-2.0 | Active (2026-10-16) | RA updater | dc_boot.bin etc. | same |
| mGBA / Gambatte / SameBoy (core) | GB/GBC/GBA | arm64 | RA | MPL-2.0 / GPL-2 / MIT | Active (2026-09-17 / 08-21 / nc) | RA updater | Optional GBA BIOS | same |
| Snes9x / bsnes | SNES | arm64 | RA | Non-commercial / GPL-3 (nc) | Active (2026-09-19 / 09-04) | RA updater | None (SGB optional) | same |
| Nestopia / Mesen | NES | arm64 | RA | GPL-2.0 / GPL-3.0 | Active (2026-10-14) / slow (2026-04-20) | RA updater | FDS BIOS | same |
| melonDS / DeSmuME | NDS | arm64 | RA | GPL | Active / abandoned core (nc) | RA updater | Optional BIOS | same |
| Azahar (libretro) | 3DS | **macOS arm64 + x86_64 core asset** | RA | GPL-2.0+ | Active; 2127.0-alpha3, 2026-10-16 (prerelease) [24] | RA updater (nc) / GitHub | Firmware dumps | same |
| PPSSPP (core) | PSP | arm64 | RA | GPL-2.0+ | Active | RA updater | None | same |
| FBNeo | Arcade, Neo Geo, CPS | arm64 | RA | Non-commercial custom [61] | Active (2026-10-18) | RA updater | Romsets, neogeo.zip | same |
| MAME 2003-Plus | Arcade (MAME 0.78 romsets) | arm64 | RA | MAME non-commercial | Active (2026-10-17) | RA updater | Romsets | same |
| Beetle PCE / Beetle VB / Beetle WonderSwan / Beetle NGP | PC Engine, Virtual Boy, WonderSwan, Neo Geo Pocket | arm64 | RA | GPL-2.0 | Active (2026-09-26 / 10-12 / 07-31 / 06-14) | RA updater | PCE-CD BIOS (syscard3.pce) | same |
| Handy / Virtual Jaguar | Lynx / Jaguar | arm64 | RA | zlib-ish (nc) / GPL-3.0 | Active (Jaguar v3.9.1, 2026-10-17); Handy pushed 2026-04-20 | RA updater | Lynx boot ROM optional; Jaguar BIOS | same |
| ProSystem / Stella (2014) / a5200 | Atari 7800 / 2600 / 5200 | arm64 | RA | GPL-2 | Active (2026-08-22 / 09-04 / nc) | RA updater | 7800 BIOS optional; 5200 BIOS | same |
| Opera | 3DO | arm64 | RA | Custom/none (nc) | Active (2026-10-13) | RA updater | 3DO BIOS | same |
| NeoCD | Neo Geo CD | arm64 | RA | NOASSERTION | Active (2026-10-03) | RA updater | neocd BIOS | same |
| vecx / FreeIntv | Vectrex / Intellivision | arm64 | RA | GPL / GPL (nc) | Vectrex nc / FreeIntv pushed 2026-08-11 | RA updater | Intellivision exec.bin + grom.bin | same |
| blueMSX / fMSX | MSX | arm64 | RA | GPL-2 (nc) | blueMSX pushed 2026-08-23 | RA updater | MSX system ROMs | same |
| VICE (x64/x128/xvic...) | Commodore | arm64 | RA | GPL-2 | Active (2026-10-03) | RA updater | Bundled free ROMs | same |
| PUAE / Amiberry core | Amiga | arm64 (Amiberry `amiberry-libretro-macOS-arm64.dylib`) | RA | GPL | PUAE abandoned (2014 repo); Amiberry core active [43] | RA updater / GitHub | Kickstart ROMs | same |
| DOSBox Pure | DOS | arm64 | RA | GPL-2.0 | Active (2026-10-06) | RA updater | None | `retroarch -L dosbox_pure_libretro.dylib game.zip` |
| ScummVM (core) | Adventure games | arm64 | RA | GPL-3.0 | Active (2026-09-22) | RA updater | None | same |
| NP2kai / Neko Project | NEC PC-98 | arm64 | RA | MIT | Active (2026-09-13) | RA updater | PC-98 BIOS | same |
| PX68k | Sharp X68000 | arm64 | RA | GPL-2 (nc) | Active (2026-08-22) | RA updater | X68000 BIOS | same |
| Atari800 core | Atari 8-bit/5200 | arm64 | RA | GPL-2.0 | Active (7.2.1, 2026-09-13) [60] | RA updater | OS ROMs | same |
| Dolphin (core) | GC/Wii | arm64 (nc: perf poor) | RA | GPL-2.0+ | Active (2026-10-16) | RA updater | Optional | same |
| Fuse (core) | ZX Spectrum | arm64 | RA | GPL-2 | nc | RA updater | Bundled | same |
| PCSX2 (core) | PS2 | **Not on macOS** (nc) | n/a | GPL-3 | n/a | n/a | n/a | n/a |

---

## 2. Nintendo

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| FCEUX | NES/Famicom | arm64 native (`fceux-2.7.0-macos-arm64.dmg`) | SDL/OpenGL | GPL-2.0+ (mixed) | Active; 2.7.0, 2026-10-14 [32] | `brew install fceux` | FDS BIOS | `fceux <rom>` |
| Nestopia (Mac port) | NES | Intel-era (nc arm64) | OpenGL (nc) | GPL-2.0 | Stale; cask 1.4.5 (nc date) [68] | `brew install --cask nestopia` | FDS BIOS | GUI only (nc) |
| MesenCE (successor of Mesen2) | NES, SNES, GB/GBC/GBA, PCE, SMS/GG, WonderSwan | arm64 native | SDL/OpenGL | GPL-3.0 | Active; 2.2.1, 2026-06-05. **Original SourMesen/Mesen2 repo archived** (2.1.1, 2025-07-06) [33] | GitHub release zip (`Mesen_2.2.1_macOS_ARM64_AppleSilicon.zip`) | Optional | `Mesen <rom>` (nc) |
| Snes9x | SNES | Universal (cask 1.63 Mac build) | OpenGL/Metal (nc) | Custom non-commercial licence [34] | Slow; 1.63, 2024-07-09 [34] | `brew install --cask snes9x` | None | Mac GUI: `open -a Snes9x <rom>`; CLI not documented (nc) |
| bsnes | SNES (accuracy) | Source builds; no official macOS binary (nc) | n/a | GPL-3.0 | Slow; v115, 2020-03-20 (repo pushed 2026-10-07) [35] | Build from source | None | `bsnes <rom>` |
| higan | Multi (legacy) | none | n/a | ISC-like | **Abandoned** (v115, 2020) [35] | n/a | n/a | n/a |
| Mupen64Plus | N64 | arm64 formula | OpenGL (plugins) | GPL-2.0+ | Slow; 2.6.0, 2024-07-15 [59] | `brew install mupen64plus` | None | `mupen64plus --fullscreen <rom>` |
| RMG (Rosalie's Mupen GUI) | N64 | arm64 (nc; macOS release asset not listed) | OpenGL (GLideN64/angrylion) | GPL-3.0 | Active; v0.9.0, 2026-06-14 [58] | GitHub (macOS builds nc) | None | `RMG <rom>`, `-f` (nc) |
| ParaLLEl-RDP / simple64 | N64 | nc | Vulkan | GPL | nc | nc | None | nc |
| Dolphin | GameCube, Wii | Universal (`dolphin-2609a-universal.dmg`) | Metal, Vulkan (MoltenVK), OpenGL (nc) | GPL-2.0+ | Active; 2609a (Homebrew cask) [16] | `brew install --cask dolphin` (also `dolphin@dev`); dolphin-emu.org | Optional (IPL), Wii NAND optional | `Dolphin.app/Contents/MacOS/Dolphin -b -e <iso>` (`-b` batch, `-e` exec) |
| Slippi Dolphin | Melee netplay | cask `slippi-dolphin` (arch nc) | OpenGL/Metal (nc) | GPL-2.0+ | nc | `brew install --cask slippi-dolphin` | None | via Slippi launcher |
| Cemu | Wii U | **Rosetta only** (`cemu-2.6-macos-12-x64.dmg`) | Vulkan via MoltenVK (nc) | MPL-2.0 | Active repo (pushed 2026-10-15) but last release v2.6, 2025-02-06 [17] | cemu.info / GitHub dmg. **Do not** use cask `cemu` (CEmu, a TI calculator) [62] | Online files/keys for some (user-supplied) | `Cemu -g <game.rpx|wua> -f` |
| Ryubing (Ryujinx fork) | Switch | arm64 native, "Only Apple Silicon Macs are properly supported" [18] | Vulkan via MoltenVK (nc) | MIT | Active; version/date not shown on download page, commits Jul 2026 (secondary) [18]. Original Ryujinx discontinued Oct 2024; GitHub mirror DMCA-blocked 2025-03 [62] | ryujinx.app/download (no brew) | prod.keys + firmware (user-supplied) | `Ryujinx <game.nsp|xci> [-f]` (nc) |
| Eden | Switch (yuzu-lineage fork) | macOS dmg published (`Eden-macOS-v0.2.1.dmg`; arch nc) | Vulkan via MoltenVK (nc) | GPL-3.0 | Active; v0.2.1, 2026-06-01 (Gitea) [19] | git.eden-emu.dev / eden-emu.dev | prod.keys + firmware | `eden -g <game>` (nc) |
| Yuzu | Switch | n/a | n/a | GPL-3.0 | **Discontinued** March 2024 (Nintendo settlement) [62] | n/a | n/a | n/a |
| Citron / Sudachi / Suyu | Switch (yuzu forks) | Sudachi listed for macOS (secondary), Citron Win/Linux/Android | Vulkan | GPL-3.0 | nc; Citron hit by DMCA Feb 2026, Sudachi generally unmaintained (secondary) [62] | nc | keys + firmware | nc |
| Kenji-NX | Switch (Ryujinx fork) | nc | nc | nc | nc | nc | keys | nc |
| mGBA | GB/GBC/GBA | Universal (mGBA-0.10.5-macos.dmg) | OpenGL | MPL-2.0 | Active; 0.10.5, 2025-03-09; repo pushed 2026-10-17 [20] | cask `mgba-app` (formula `mgba` is **deprecated**, Qt5 EOL, disable 2027-05-19) | Optional GBA BIOS | `mgba-qt <rom> -f` or SDL `mgba <rom>` |
| SameBoy | GB/GBC | Universal | Metal | MIT (Expat) | Active; v1.0.4, 2026-10-09 [21] | `brew install --cask sameboy` | Bundled boot ROMs | `SameBoy.app/Contents/MacOS/SameBoy <rom>`; SDL `sameboy <rom>` |
| NanoBoyAdvance | GBA | arm64 dmg | OpenGL | GPL-3.0 | **Repo archived** 2026-06; v1.8.3, 2026-05-10 [38] | GitHub dmg | Optional BIOS | `NanoBoyAdvance <rom>` (nc) |
| VBA-M | GB/GBA | nc | OpenGL | GPL-2 | nc | nc | Optional | nc |
| melonDS | NDS/DSi | Universal (`melonDS-1.1-macOS-universal.zip`) | OpenGL (Metal nc) | GPL-3.0 | Active; 1.1, 2025-11-18 (pushed 2026-08-23) [22] | GitHub zip (cask `melonds` *disabled*) | Optional; DSi needs BIOS/NAND | `melonDS <rom.nds>` (nc) |
| DeSmuME | NDS | macOS dmg (0.9.13, arch nc) | OpenGL | GPL-2.0 | **Slow/near-abandoned**; 0.9.13, 2022-05-23 (pushed 2026-09-11) [23] | GitHub dmg (cask *disabled*) | Optional | `desmume <rom>` |
| Azahar | 3DS | macOS builds (arm64 + x86_64 per libretro assets) | Vulkan via MoltenVK, OpenGL (nc) | GPL-3.0 | Active; 2126.2 stable 2026-10-08; 2127.0-alpha3 2026-10-16 [24] | azahar-emu.org / GitHub | Optional (AES keys, system archives) | `azahar <rom.3ds>` (nc) |
| Lime3DS | 3DS | macOS (same release assets as Azahar mirror) | as above | GPL-3.0 | Mirrors Azahar releases (same tag 2126.2) [25] | GitHub | as above | as above |
| Citra | 3DS | n/a | n/a | GPL-2 | **Discontinued** March 2024; successors Azahar (maintained), Lime3DS [62] | n/a | n/a | n/a |
| Panda3DS | 3DS | macOS Qt + SDL builds (arch nc) | Vulkan/MoltenVK/OpenGL (nc) | GPL-3.0 | Slow; v0.9, 2024-12-25 (pushed 2026-10-04) [26] | GitHub zip | 3DS dumps | `Alber <rom.3ds>` (nc) |
| Virtual Boy | Beetle VB core (see libretro) | arm64 | | GPL-2.0 | Active | | | |
| Pokemon Mini / others | PokeMini libretro | nc | | | nc | | | |
| NanoBoy / No$GBA | | Windows only | | | | | | |

---

## 3. Sony

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| DuckStation | PS1 | Universal (macOS 13.3+) | Metal, Vulkan, OpenGL (README) [8] | **CC BY-NC-ND 4.0** (LICENSE file; no commercial use, no derivatives) [8] | Active; rolling `latest` 2026-10-13 and `preview` 2026-10-18; no semver [8] | GitHub release `duckstation-mac-release.zip`; no cask | PS1 BIOS (user-supplied) | `DuckStation.app/Contents/MacOS/DuckStation -batch -fullscreen -- <game.cue>` |
| PCSX2 | PS2 | arm64 (Qt macOS tarball) | Metal, Vulkan/MoltenVK (nc), OpenGL | GPL-3.0 | Active; stable v2.8.2 (2026-09-04); nightly v2.9.129 (2026-10-16) [9] | `brew install --cask pcsx2`; pcsx2.net | PS2 BIOS (user-supplied) | `PCSX2 -batch -fullscreen -- <game.iso>` |
| Play! | PS2 | macOS build available (arch nc) | Metal/OpenGL/Vulkan (nc) | BSD-2-Clause [10] | Active; tag 0.77 (2026-06-29 commit); pushed 2026-10-14 [10] | purei.org, cask `purei-play` | None (HLE BIOS) | `Play --disc <iso>` (nc) |
| RPCS3 | PS3 | arm64 builds exist but experimental (separate repos `rpcs3-binaries-mac`, `rpcs3-binaries-mac-arm64`) | Vulkan via MoltenVK | GPL-2.0 | Active; v0.0.43, 2026-09-30 (Windows/Linux release); mac binaries in separate repos, latest listed 2026-08-16 (nc which arch) [11] | GitHub / rpcs3.net; no cask | PS3 firmware (PS3UPDAT.PUP, user-supplied) | `rpcs3 --no-gui <EBOOT.BIN>` |
| PPSSPP | PSP | arm64 (SDL macOS zip `PPSSPPSDL-macOS-v1.20.4.zip`) | Vulkan/MoltenVK, OpenGL | GPL-2.0+ and BSD-3 | Active; v1.20.4, 2026-05-16 [12] | `brew install ppsspp` formula; cask `ppsspp-emulator` | None | `PPSSPPSDL <game.iso> [--fullscreen]` |
| Vita3K | PS Vita | arm64 dmg (`macos-arm64-latest.dmg`) | Vulkan via MoltenVK | GPL-2.0 | Active; rolling `continuous`, 2026-10-18 [13] | GitHub dmg | PS Vita firmware + fonts (user-supplied) | `Vita3K -r <TITLE_ID>` |
| shadPS4 | PS4 | macOS SDL zip in nightlies (`shadps4-macos-sdl-...zip`, arch nc) | Vulkan/MoltenVK (nc) | GPL-2.0 | Active, **pre-release/alpha**; v.0.20.0 (2026-10-14) + daily prereleases [14] | GitHub / shadps4.net | Optional | `shadPS4 <eboot.bin>` (`-g <path>`; nc exact flags) |
| RPCSX | PS4 / PS3 alt | Linux/Android | | GPL-2.0 | Stale; last release 2023-11 [63] | n/a | | |
| Mednafen / Beetle PSX / SwanStation | PS1 | see sections 1 | | | | | | |
| pcsx-redux | PS1 dev | nc | OpenGL | GPL | nc | | | |

---

## 4. Microsoft

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| xemu | Original Xbox | Universal (`...macos-universal-unsigned.zip`) | OpenGL (Vulkan work in progress, nc) | GPL-2.0 (QEMU-derived) [15] | Active; stable v0.8.137 (cask), pre-release builds 2026-10-18 [15] | `brew install --cask xemu`; xemu.app | MCPX boot ROM, flash BIOS, HDD image (user-supplied) | `xemu -dvd_path <iso>` (QEMU-style flags) |
| Xenia / Xenia Canary | Xbox 360 | **No macOS build** | D3D12/Vulkan | BSD-3 (nc) | Canary active (commit 2026-10-18) but Windows/Linux only [64] | n/a | n/a | n/a |
| Xbox 360 on mac | | **Gap**: only via Wine/CrossOver/GPTK (not confirmed to work) | | | | | | |

---

## 5. Sega

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| BlastEm | SMS/GG, Genesis/Mega Drive, Sega CD (partial) | arm64 formula | OpenGL | GPL-3.0+ (formula) | Slow; 1.0.0 stable per Homebrew; hg repo at retrodev.com [29] | `brew install blastem` | Optional | `blastem <rom>` |
| Genesis Plus (Mac, Bannister) | SMS, GG, Genesis, MCD | cask `genesis-plus` 1.3.5 (arch nc) | OpenGL | Non-commercial custom (nc) | Stale (nc) | `brew install --cask genesis-plus` | MCD BIOS | GUI |
| Genesis Plus GX (standalone) | as above | via RetroArch/OpenEmu core | | | see libretro | | | |
| Kronos | Saturn | No macOS release asset in 2.7.0 (2025-01-16) [30] | OpenGL/Vulkan | GPL-2.0 | Slow; 2.7.0, 2025-01-16; repo pushed 2026-07-18 [30] | RetroArch Kronos core | Saturn BIOS | `kronos -a -i <cue>` (nc) |
| Ymir | Saturn | arm64 + x64 zips (`ymir-macos-arm64-v0.4.1.zip`) | Metal-less; OpenGL/Vulkan (nc) | GPL-3.0 | **Very active**; v0.4.1, 2026-10-18 [31] | GitHub zip | Saturn BIOS (user-supplied) | `ymir <game.cue>` (nc) |
| Yabause | Saturn | nc | OpenGL | GPL-2 | Stale (pushed 2024-03) [30] | n/a | BIOS | nc |
| Mednafen (Saturn) | Saturn | arm64 | | | see section 1 | | | |
| Flycast | Dreamcast, Naomi, Atomiswave | macOS zip (`flycast-macOS-2.7.zip`; arch nc) | Vulkan/MoltenVK, OpenGL | GPL-2.0 | Active; v2.7, 2026-08-19 [27] | GitHub; cask `flycast` *disabled* | dc_boot.bin/dc_flash.bin (HLE exists) | `flycast <content>` |
| Redream | Dreamcast | cask `redream` 1.5.0 *disabled*; Intel/Rosetta (nc) | OpenGL | Closed source, freeware | Stale/nc [65] | redream.io | None | `redream <game>` (nc) |
| Hypseus Singe | Laserdisc (Dragon's Lair, Space Ace, Singe) | arm64 (`...macOS-arm64-Tahoe.zip`) | OpenGL/SDL | GPL-3.0 | Active; v3.0.2, 2026-08-30 [51] | GitHub zip | Game ROMs + video | `hypseus <game> vldp -framefile ... -fullscreen` |

---

## 6. Atari, NEC, SNK, Bandai, 3DO, Philips, others

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| Stella | Atari 2600 | cask `stella-app` / formula `stella` 7.0c (arm64 bottle); official 7.0 Mac dmg (Intel+ARM nc) | OpenGL/SDL | GPL-2.0+ | Active; 7.0 (2024-10-05), Homebrew 7.0c; repo pushed 2026-10-15 [28] | `brew install stella` / cask `stella-app` | None | `Stella <rom.a26>` |
| Atari800 | Atari 400/800/XL/XE/5200 | arm64 formula | SDL | GPL-2.0+ | Active; 7.2.1, 2026-09-13 [60] | `brew install atari800` | OS ROMs | `atari800 -run game.xex` |
| ProSystem / A7800 | Atari 7800 | via RetroArch | | | see libretro | | 7800 BIOS optional | |
| Virtual Jaguar | Atari Jaguar | via libretro (v3.9.1, 2026-10-17) | | GPL-3.0 | Active | RA | Jaguar BIOS | |
| Hatari | Atari ST/STE/TT/Falcon | arm64 formula 2.6.1 | SDL | GPL-2.0+ | Active (mirror pushed 2026-10-18) [53] | `brew install hatari` | TOS ROMs (EmuTOS bundled) | `hatari [--fullscreen] disk.st` |
| Gearlynx / Handy | Atari Lynx | arm64 | OpenGL | GPL-3.0 | Active (1.2.35) [36] | GitHub zip | Optional boot ROM | `gearlynx <rom>` (nc) |
| Geargrafx / Mednafen / Beetle PCE | PC Engine / TG-16 / SuperGrafx | arm64 | OpenGL | GPL-3.0 | Active (1.8.4, 2026-10-15) [36] | GitHub zip | syscard3.pce for CD | `geargrafx <rom>` (nc) |
| Neo Geo (FBNeo, MAME, ares, NeoCD) | Neo Geo MVS/AES/CD | see libretro | | | | | neogeo.zip | |
| Neo Geo Pocket | Beetle NGP / ares | | | | | | | |
| WonderSwan | ares / MesenCE / Beetle WSwan | arm64 | | | | | optional | |
| Opera | 3DO | via libretro (2026-10-13) | | custom | Active | RA | 3DO BIOS | |
| CD-i (Philips) | MAME (cdimono1) | arm64 | | | via MAME | `brew install mame` | CD-i BIOS ROM | `mame cdimono1 -cdrom game.chd` |
| Vectrex | vecx core, MAME | via libretro/MAME | | | | | | |
| ColecoVision | Gearcoleco, ares, MAME | arm64 | OpenGL | GPL-3.0 | Active (1.7.4) [36] | GitHub zip | BIOS | |
| Intellivision | FreeIntv core, MAME | via libretro | | GPL | Active (2026-08-11) | RA | exec.bin/grom.bin | |

---

## 7. Computers

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| DOSBox Staging | DOS | Universal (`dosbox-staging-macOS-v0.83.0.dmg`) | OpenGL/SDL | GPL-2.0+ | Active; v0.83.0, 2026-08-27 [39] | `brew install dosbox-staging` / cask `dosbox-staging-app` | None | `dosbox <dir|exe|conf> [-conf file] [--fullscreen]` |
| DOSBox-X | DOS/Win9x/PC-98 | arm64 + x86_64 zips | OpenGL/SDL | GPL-2.0+ | Active; 2026.10.01, 2026-10-02 [40] | `brew install dosbox-x`; cask `dosbox-x-app` is *disabled* | None | `dosbox-x -conf <file> -fullscreen` |
| DOSBox (original) | DOS | cask 0.74-3 | SDL | GPL-2 | **Abandoned** | `brew install --cask dosbox` | None | `dosbox <exe>` |
| Boxer | DOS wrapper | Intel only (nc) | | GPL | **Abandoned** (nc) | n/a | | |
| ScummVM | Adventure engines | arm64 (formula + cask `scummvm-app`) | OpenGL/SDL | GPL-3.0+ | Active; v2026.4.0, 2026-10-11 [41] | `brew install scummvm` / cask `scummvm-app` | None | `scummvm -f <gameid>` (`--path=<dir>`, `--add`) |
| VICE | C64/C128/VIC-20/PET/Plus4 | arm64 dmg (gtk3/sdl2) | GTK3/SDL2 | GPL-2.0+ | Active; 3.10, 2025-12-24; r46274 snapshot 2026-09-27 [42] | `brew install vice`; official dmg | Bundled free ROMs | `x64sc -autostart <d64|prg|crt>` |
| Amiberry | Amiga | Universal dmg 8.4.1 | SDL/OpenGL | GPL-3.0 | Active; v8.4.1, 2026-10-14 [43] | `brew install --cask amiberry` | Kickstart ROMs | `amiberry -f <cfg.uae>` / `--model A1200 -s ...` (nc) |
| FS-UAE | Amiga | arm64 formula/cask 3.2.35 | OpenGL/SDL | GPL-2.0+ | Slow; v3.2.35, 2025-09-07 [44] | `brew install fs-uae` / cask `fs-uae-emulator` | Kickstart | `fs-uae <config.fs-uae>` |
| vAmiga | Amiga 500/1000/2000 | Universal (nc) | Metal | Custom/GPL (nc) | Active; v5.0b2 prerelease 2026-09-01 [45] | cask `vamiga` 4.5 | Optional (Aros built in) | GUI (nc) |
| Clock Signal (CLK) | ZX80/81, Amstrad CPC, Apple II, Atari ST, Acorn, BBC, C64 (partial), Mac 512K, MSX, ColecoVision, Oric, Vic-20, ZX Spectrum | Universal | Metal/OpenGL | MIT | Active; 2026-07-23 [46] | `brew install --cask clock-signal` | Bundled? ROMs user-supplied (nc) | GUI; open file via `open -a "Clock Signal" <file>` |
| Fuse | ZX Spectrum | source / mac build via official site (arm64 nc) | SDL | GPL-2.0+ | Active (mirror pushed 2026-10-18) [56] | fuse-emulator.sourceforge.net | Bundled | `fuse <tape.tzx>` |
| Retro Virtual Machine 2 | ZX Spectrum, Amstrad CPC | Universal (nc) | Metal/OpenGL | Closed source, freeware/paid (nc) | 2.1.20 (Homebrew) | cask `retro-virtual-machine` | Bundled | GUI |
| openMSX | MSX | arm64 formula 21.0 | OpenGL/SDL | GPL-2.0 | Active; RELEASE_21_0, 2025-09-26 [47] | `brew install openmsx`; cask `openmsx-emulator` *disabled* | C-BIOS bundled; real BIOS optional | `openmsx -cart <rom>` / `-diska <dsk>` |
| XRoar | Dragon/CoCo | arm64 formula 1.12.1 | SDL | GPL-3.0+ | Active (nc date) [61b] | `brew install xroar` | ROMs | `xroar -machine coco2 -run game.cas` |
| Basilisk II / SheepShaver | 68k Mac / PowerPC Mac | SheepShaver.dmg from kanjitalk755 fork (arch nc, mostly x86_64/Rosetta) | SDL | GPL-2 | Basilisk/Sheep fork repo pushed 2026-08-30; last tagged release 2017 [54] | GitHub | Mac ROM (user-supplied) | `BasiliskII --config <file>` (nc) |
| Mini vMac | Mac Plus/II/128K | cask `mini-vmac` 36.04 | SDL | GPL-2 | Stable/slow; 36.04 | `brew install --cask mini-vmac` | Mac ROM | no CLI; drag disk |
| 86Box | PC (8086..Pentium 4, Win9x) | Universal (`86Box-macOS-x86_64+arm64`) | OpenGL/SDL | GPL-2.0 | Active; v6.0, 2026-05-31 [48] | `brew install --cask 86box` | ROM set via separate repo (user-supplied) | `86Box -P <vm_dir>` |
| UTM | QEMU / Apple Virtualization VMs | Universal | Metal | Apache-2.0 | Active; v5.0.8, 2026-10-17 [49] | `brew install --cask utm` | Guest-specific | `utmctl start <VM>`, `open utm://...` |
| QEMU | Generic | arm64 formula 11.1.2 | Cocoa/SDL | GPL-2.0 | Active [50] | `brew install qemu` | Per machine | `qemu-system-<arch> ...` |
| Bochs | x86 PC | arm64 formula 3.1 | | LGPL | Active (nc) | `brew install bochs` | | `bochs -f bochsrc` |
| PCem | PC | nc | | GPL | superseded by 86Box | | | |
| MAME (computers) | everything | see section 1 | | | | | | |
| NP2kai / PX68k | PC-98 / X68000 | libretro cores | | | | | | |

---

## 8. Fantasy consoles and misc

| Emulator | Systems | Apple silicon | Graphics API | License | Status + latest | Install | BIOS/firmware | CLI launch |
|---|---|---|---|---|---|---|---|---|
| PICO-8 | Fantasy console | Universal/ARM (nc) | SDL/OpenGL | **Closed source, paid** | Active (nc) [57] | lexaloffle.com (paid) | None | `pico8 -run <cart.p8>` |
| TIC-80 | Fantasy console | arm64 dmg (`tic80-v1.3-mac-arm64.dmg`) | SDL/OpenGL | MIT | Active; v1.3.1, 2026-10-05 [52] | cask `tic80`; GitHub | None | `tic80 [--fs .] <cart.tic>` |
| Hypseus Singe | Laserdisc | see Sega section | | GPL-3.0 | Active | | | |
| LOVE | Lua game framework | cask `love` | | zlib | Active | `brew install --cask love` | | `love <dir>` |
| GZDoom | Doom engine (not an emulator) | macOS zip 4.14.2 | OpenGL/Vulkan | GPL-3.0 | Slow; g4.14.2, 2025-05-03 | GitHub; cask `gzdoom` | WAD (user-supplied) | `gzdoom -iwad <wad>` |

---

## Best pick per system (support first)

- Multi-system frontend: **RetroArch** (cask `retroarch-metal`).
- NES: FCEUX (standalone) or MesenCE; core: Nestopia.
- SNES: Snes9x core via RetroArch (bsnes for accuracy).
- N64: Mupen64Plus-Next core (standalone: RMG, nc macOS).
- GameCube/Wii: **Dolphin**.
- Wii U: **Cemu** (Rosetta only; flag as limited).
- Switch: **Ryubing** (arm64). Eden as second option.
- GB/GBC: SameBoy. GBA: mGBA. NDS: melonDS. 3DS: **Azahar**.
- PS1: **DuckStation** (licence caveat; fallback SwanStation core).
- PS2: **PCSX2**. PSP: **PPSSPP**. Vita: **Vita3K**. PS3: RPCS3 (experimental). PS4: shadPS4 (alpha).
- Xbox: **xemu**. Xbox 360: none (gap).
- Master System/Genesis/CD/32X/Game Gear: Genesis Plus GX core; standalone BlastEm.
- Saturn: **Ymir** (new, active) then Mednafen/Kronos core.
- Dreamcast/Naomi: **Flycast**.
- Atari 2600: Stella. 7800/5200/8-bit: Atari800 / libretro cores. Lynx: Gearlynx. Jaguar: Virtual Jaguar core. ST: Hatari.
- PC Engine: Geargrafx. Neo Geo: FBNeo core / MAME. WonderSwan: ares or MesenCE. 3DO: Opera core. CD-i: MAME. Vectrex/Intellivision/ColecoVision: libretro cores / Gearcoleco.
- Arcade: **MAME**; laserdisc: Hypseus Singe.
- DOS: **DOSBox Staging**. ScummVM: ScummVM. Commodore: VICE. Amiga: Amiberry. Spectrum: Fuse / Clock Signal. MSX: openMSX. Apple II: Clock Signal. Classic Mac: Mini vMac / SheepShaver. Old PC: 86Box. Other OS/VMs: UTM.
- Fantasy: TIC-80 (open) and PICO-8 (paid).
- Frontend to read for inspiration or interop: ES-DE (command templates in `es_systems.xml`).

## Integration notes

- **Detection**: look for `.app` bundles in `/Applications` and `~/Applications`, then for Homebrew binaries in `/opt/homebrew/bin`. Executable inside a bundle: `<App>.app/Contents/MacOS/<Name>`.
- **Launch**: prefer the inner binary with CLI args (Dolphin `-b -e`, PCSX2/DuckStation `-batch -fullscreen --`, PPSSPP `PPSSPPSDL`, RetroArch `-L core rom`, Vita3K `-r TITLEID`, RPCS3 `--no-gui`). For GUI-only apps fall back to `open -a <App> --args ...` or `open -a <App> <file>`.
- **Scriptable interfaces**: UTM has `utmctl` (and `utm://` URL scheme). RetroArch has a network command interface (UDP port 55355) and `--config`. MAME has `-listxml` and Lua scripting. ScummVM has `--list-games` and `--add`. ES-DE reads `es_systems.xml` with `%ROM%` templates, a proven pattern to copy.
- **Config paths** (typical, verify per release): RetroArch `~/Library/Application Support/RetroArch`; Dolphin `~/Library/Application Support/Dolphin`; PCSX2 `~/Library/Application Support/PCSX2`; DuckStation `~/Library/Application Support/DuckStation`; Azahar `~/.config/azahar-emu` (nc); Ryubing `~/Library/Application Support/Ryujinx` (nc); ScummVM `~/Library/Preferences/ScummVM Preferences`; DOSBox Staging `~/Library/Preferences/DOSBox`. Mark all as nc, not read from primary docs.
- **Gatekeeper**: several GitHub builds are unsigned (xemu `-unsigned`, many Homebrew casks disabled 2026-09-01 for failing the Gatekeeper check). Launching may require `xattr -dr com.apple.quarantine <app>` by the user; Cartouche should explain this rather than run it silently.
- **Rosetta only**: Cemu 2.6 (x64 dmg). Cartouche should warn and offer to check Rosetta.
- **BIOS/firmware**: never ship or link them. Cartouche should only check for user-provided files and report what is missing.
- **Licensing for bundling**: GPL emulators (most) can be redistributed with source offer but make Cartouche's distribution GPL-aware. DuckStation (CC BY-NC-ND), Snes9x and Genesis Plus GX/FBNeo/MAME-2003-Plus (non-commercial), and closed source (PICO-8, Redream, Retro Virtual Machine) must not be bundled. Safest: detect and launch only, with "Download" links to official sites.
- **Legal risk**: Switch emulator ecosystem is volatile (Yuzu and Citra shut down 2024, Ryujinx moved off GitHub after DMCA in 2025, Citron DMCA 2026 per secondary sources). Treat Switch/3DS support as pluggable and best-effort.

## Gaps

- **Xbox 360**: no macOS emulator (Xenia is Windows/Linux).
- **PS4**: shadPS4 alpha on macOS, many games do not run.
- **PS3**: RPCS3 macOS arm64 is experimental and slow.
- **Wii U**: Cemu has no arm64 macOS build (Rosetta).
- **Switch**: working options exist (Ryubing, Eden) but legal status shaky; version info not confirmed.
- **Wii U / 3DS / Switch encryption keys** are user-supplied.
- **Saturn**: Kronos has no macOS asset; Ymir is the best new option.
- **Not confirmed**: arm64 status of Play!, Panda3DS, shadPS4, RMG, vAmiga macOS builds; many exact CLI flags and config paths.

## Sources

Fetched 2026-10-18. GitHub data from `gh api repos/<repo>/releases` and `/repos/<repo>`. Homebrew data from formulae.brew.sh JSON API.

1. https://github.com/libretro/RetroArch/releases ; https://formulae.brew.sh/cask/retroarch ; https://formulae.brew.sh/cask/retroarch-metal
2. https://github.com/OpenEmu/OpenEmu/releases ; https://formulae.brew.sh/cask/openemu
3. https://github.com/ares-emulator/ares/releases ; https://formulae.brew.sh/cask/ares-emulator
4. https://github.com/mamedev/mame/releases ; https://formulae.brew.sh/formula/mame
5. https://mednafen.github.io/releases/ ; https://formulae.brew.sh/formula/mednafen
6. https://gitlab.com/es-de/emulationstation-de/-/releases ; https://formulae.brew.sh/cask/es-de
7. https://github.com/mmatyas/pegasus-frontend (README and releases)
8. https://github.com/stenzek/duckstation/releases ; LICENSE and README in repo
9. https://github.com/PCSX2/pcsx2/releases ; https://formulae.brew.sh/cask/pcsx2
10. https://github.com/jpd002/Play- ; https://purei.org
11. https://github.com/RPCS3/rpcs3/releases ; https://github.com/RPCS3/rpcs3-binaries-mac ; https://github.com/RPCS3/rpcs3-binaries-mac-arm64
12. https://github.com/hrydgard/ppsspp/releases ; https://formulae.brew.sh/formula/ppsspp
13. https://github.com/Vita3K/Vita3K/releases
14. https://github.com/shadps4-emu/shadPS4/releases
15. https://github.com/xemu-project/xemu/releases ; https://formulae.brew.sh/cask/xemu
16. https://formulae.brew.sh/cask/dolphin ; https://github.com/dolphin-emu/dolphin (LICENSE)
17. https://github.com/cemu-project/Cemu/releases
18. https://ryujinx.app/download (page text only; no version shown)
19. https://git.eden-emu.dev/eden-emu/eden/releases
20. https://github.com/mgba-emu/mgba/releases ; https://formulae.brew.sh/formula/mgba (deprecated) ; https://formulae.brew.sh/cask/mgba-app
21. https://github.com/LIJI32/SameBoy/releases ; https://formulae.brew.sh/cask/sameboy
22. https://github.com/melonDS-emu/melonDS/releases ; https://formulae.brew.sh/cask/melonds
23. https://github.com/TASEmulators/desmume/releases ; https://formulae.brew.sh/cask/desmume
24. https://github.com/azahar-emu/azahar/releases
25. https://github.com/Lime3DS/Lime3DS/releases
26. https://github.com/wheremyfoodat/Panda3DS/releases
27. https://github.com/flyinghead/flycast/releases ; https://formulae.brew.sh/cask/flycast
28. https://github.com/Stella-emu/stella/releases ; https://formulae.brew.sh/formula/stella ; https://formulae.brew.sh/cask/stella-app
29. https://formulae.brew.sh/formula/blastem ; https://www.retrodev.com/blastem/
30. https://github.com/FCare/Kronos/releases ; https://github.com/Yabause/yabause
31. https://github.com/StrikerX3/ymir/releases
32. https://github.com/TASEmulators/fceux/releases
33. https://github.com/nesdev-org/MesenCE/releases ; https://github.com/SourMesen/Mesen2 (archive notice)
34. https://github.com/snes9xgit/snes9x/releases ; https://formulae.brew.sh/cask/snes9x
35. https://github.com/bsnes-emu/bsnes ; https://github.com/higan-emu/higan
36. https://github.com/drhelius/Gearboy ; /Gearsystem ; /Gearcoleco ; /Geargrafx ; /Gearlynx (releases)
37. https://github.com/skylersaleh/SkyEmu/releases
38. https://github.com/nba-emu/NanoBoyAdvance
39. https://github.com/dosbox-staging/dosbox-staging/releases ; https://formulae.brew.sh/formula/dosbox-staging
40. https://github.com/joncampbell123/dosbox-x/releases ; https://formulae.brew.sh/cask/dosbox-x-app
41. https://github.com/scummvm/scummvm/releases ; https://formulae.brew.sh/formula/scummvm
42. https://github.com/VICE-Team/svn-mirror/releases ; https://formulae.brew.sh/formula/vice
43. https://github.com/BlitterStudio/amiberry/releases ; https://formulae.brew.sh/cask/amiberry
44. https://github.com/FrodeSolheim/fs-uae/releases ; https://formulae.brew.sh/formula/fs-uae
45. https://github.com/dirkwhoffmann/vAmiga/releases
46. https://github.com/TomHarte/CLK/releases ; https://formulae.brew.sh/cask/clock-signal
47. https://github.com/openMSX/openMSX/releases ; https://formulae.brew.sh/cask/openmsx-emulator
48. https://github.com/86Box/86Box/releases ; https://formulae.brew.sh/cask/86box
49. https://github.com/utmapp/UTM/releases ; https://formulae.brew.sh/cask/utm
50. https://formulae.brew.sh/formula/qemu
51. https://github.com/DirtBagXon/hypseus-singe/releases
52. https://github.com/nesbox/TIC-80/releases
53. https://github.com/hatari/hatari ; https://formulae.brew.sh/formula/hatari
54. https://github.com/kanjitalk755/macemu
55. https://formulae.brew.sh/cask/mini-vmac
56. https://github.com/Fuse-emulator/fuse
57. https://www.lexaloffle.com/pico-8.php (version not confirmed)
58. https://github.com/Rosalie241/RMG/releases
59. https://github.com/mupen64plus/mupen64plus-core ; https://formulae.brew.sh/formula/mupen64plus
60. https://github.com/atari800/atari800/releases ; https://formulae.brew.sh/formula/atari800
61. libretro core repos (activity dates via GitHub API): https://github.com/libretro (genesis_plus_gx, mupen64plus-libretro-nx, beetle-*, swanstation, flycast, mgba, snes9x, bsnes, nestopia, opera-libretro, fbneo, virtualjaguar-libretro, dosbox-pure, ScummVM, np2kai). 61b: https://formulae.brew.sh/formula/xroar
62. Discontinuations: GitHub DMCA block message returned by the API for ryujinx-mirror/ryujinx (2025-03-14) is primary; Yuzu/Citra/Citron/Sudachi status is from secondary sources (https://tecnobits.net/best-yuzu-alternatives/ , https://emulation.gametechwiki.com/index.php/Ryubing , https://emulation.gametechwiki.com/index.php/Eden) = not confirmed. Cask name collision: https://formulae.brew.sh/cask/cemu (CEmu).
63. https://github.com/RPCSX/rpcsx
64. https://github.com/xenia-canary/xenia-canary
65. https://formulae.brew.sh/cask/redream
66. Homebrew bulk data: https://formulae.brew.sh/api/cask.json ; https://formulae.brew.sh/api/formula.json
68. https://formulae.brew.sh/cask/nestopia ; https://formulae.brew.sh/cask/genesis-plus
