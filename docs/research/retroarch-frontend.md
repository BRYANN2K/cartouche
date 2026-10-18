# Cartouche as a RetroArch frontend

Date: 2026-10-18. Design notes for P12 (bonus). Facts checked today: libretro buildbot for `apple/osx/arm64` answers and is updated daily, the thumbnails server answers, core `.info` files list extensions and BIOS with MD5.

## Wrapper: yes, and RetroArch now helps (checked in the repo on 2026-10-19)

- **RetroArch has its own MCP server** on `master` (`network/mcp_server.c`, `docs/mcp-server.md`, commits up to 2026-10-17). Started with `--mcp-stdio`, the process that launches RetroArch drives it over stdin/stdout, with no token. It is **not in 1.22.2** (latest stable): it needs a nightly build until the next release.
- Tools exposed (one per network command): `LOAD_CONTENT` (core + file), `LOAD_CORE`, `STATE` (save/load a slot), `SCREENSHOT`, `GET_STATUS`, `SET_SHADER`, `GET_PLAYLIST`, `LIST_CORES`, `LIST_PLAYLISTS`, `GET_OPTION`/`SET_OPTION`, `GET_CORE_OPTION`/`SET_CORE_OPTION`, `READ_CORE_MEMORY`, `GET_MEMORY_MAP`, `SET_INPUT`/`PRESS`/`RUN_UNTIL`/`STEPS`/`WATCH`, `GET_LOG`, plus every hotkey action (pause, rewind, fast-forward, disc swap, run-ahead, AI service, netplay host, recording, streaming).
- Hardcore achievements block input from commands (`SET_INPUT` refuses), so an agent cannot cheat on RetroAchievements.
- Stable 1.22.2 already has the UDP network commands (`GET_STATUS`, `SHOW_MSG`, `READ_CORE_MEMORY`, `LOAD_STATE_SLOT`, `GET_CONFIG_PARAM` and the hotkey actions) and the CLI flags `-L`, `--host`, `--connect`, `--nick`, `--port`, `--set-shader`, `--record`, `--appendconfig`, `--entryslot`, `--subsystem`, `--fullscreen`, `--log-file`.
- So Cartouche can be a **wrapper**: launch RetroArch with `--mcp-stdio`, keep the pipe, and drive it. Cartouche's own MCP (P11) can forward a game-level toolset to agents.

## What the mockup shows, and the RetroArch piece behind each

| Feature in the mockup | Built on |
|---|---|
| Consoles section, covers, screenshots | libretro-thumbnails (Named_Boxarts, Named_Snaps, Named_Titles) |
| Play / Resume, CRT power-on | `LOAD_CONTENT`, `--entryslot` / `STATE load` |
| Time Machine (save states with pictures) | RetroArch saves a PNG with each state; `STATE` loads a slot |
| Achievements and Hardcore | RetroAchievements (rcheevos) built into RetroArch |
| Look: Original, CRT, LCD | slang shader presets, `SET_SHADER` / `--set-shader` |
| Play Together | Netplay: `--host`, `--connect`, libretro relay servers |
| Lower input lag | Run-ahead (`RUNAHEAD_TOGGLE`, config) |
| BIOS status | core `.info` firmware entries with MD5 |
| Discs | Disk control (`DISK_NEXT`, `DISK_EJECT_TOGGLE`, `.m3u`) |
| Translate the screen | AI service (`AI_SERVICE`), needs a translation service URL |
| Coach mode with Claude | `READ_CORE_MEMORY`, `WATCH`, `RUN_UNTIL` through RetroArch's MCP; memory addresses per game come from RetroAchievements definitions |

Not verified yet: the exact JSON shape of each MCP tool on macOS builds, netplay relay availability, AI service setup cost.

## Decisions (2026-10-19)

- **Wrapper + frontend.** Cartouche ships its own RetroArch, drives it over MCP (stdio), and is the library and settings around it.
- **Bundled RetroArch, built by us.** RetroArch is GPL-3.0 like Cartouche. GitHub releases only carry source tarballs; macOS binaries come from the libretro buildbot. So CI builds RetroArch from a pinned commit (git submodule, Xcode project in `pkg/apple`), signs it with the Cartouche certificate, and embeds it in the app. No binary is committed to the repo. Cores are never bundled (some are non-commercial): they are downloaded per console from the libretro buildbot.
- **Version choice in Settings > Consoles:** Included with Cartouche (default), an official libretro release (downloaded from the buildbot), or the user's own copy. Official releases before the MCP server shipped fall back to the UDP network commands, with Time Machine and Coach mode limited.
- **Sidebar:** "PC" (Steam, Epic, GOG, Amazon, Windows installers) and "Consoles" (one entry per console the user added). A "+" next to Consoles opens Add Consoles; only the chosen consoles' cores are downloaded.
- **Adding games:** the toolbar "+" offers Windows Game or Console Games (drop files or a folder, identified by checksum). Game folders set in Settings > Library are watched and new games are added automatically.

## Short answer

Yes. Cartouche drives the official RetroArch app: it finds games, picks the core, checks the BIOS, shows covers, and launches `RetroArch -L <core> <rom>`. RetroArch does the emulation. Superseded on 2026-10-19: Cartouche ships its own RetroArch built from source (see Decisions above and ADR 0008). Cores are never bundled.

## Two ways to do it

| Approach | What it means | Verdict |
|---|---|---|
| **Drive RetroArch** | Launch the RetroArch app with a core and a ROM, control it over its network commands | **v1.2**. Simple, all cores, RetroArch keeps its own updates |
| Host libretro cores ourselves | Load core `.dylib` files in Cartouche and render with Metal, like OpenEmu | Later, if ever. Months of work (audio, input, save states, shaders) |

## Install

1. **Detect** `/Applications/RetroArch.app` (or the path the user picks). Read its version.
2. **If missing**: button "Install RetroArch" → `brew install --cask retroarch-metal` when Homebrew is present (this cask is still enabled), otherwise the official download page. (Superseded: Cartouche bundles RetroArch, see Decisions.)
3. **Cores on demand**: when a system has games but no core, download the recommended core from `buildbot.libretro.com/nightly/apple/osx/arm64/latest/<core>_libretro.dylib.zip` into RetroArch's `cores` folder. Cores are never shipped in Cartouche (some are non-commercial, e.g. Snes9x, Genesis Plus GX).
4. **Settings once**: enable RetroArch's network commands (`network_cmd_enable = true`, UDP 55355) in a Cartouche-owned override config passed with `--appendconfig`, so the user's own `retroarch.cfg` is never rewritten.

## Adding ROMs

- **Folders**: Settings > Library > Game Folders, plus drag and drop on the window. Cartouche watches these folders.
- **Already a RetroArch user?** Import RetroArch's playlists (`.lpl`, JSON) in one click.
- **Identification**, in this order:
  1. Checksum (CRC32, then MD5/SHA-1 for discs) against the libretro database (No-Intro and Redump names).
  2. File extension and folder name, using each core's `supported_extensions`.
  3. Otherwise: "Unknown system", and the user picks it.
- **Archives and discs**: `.zip`/`.7z` for cartridges, `.chd`/`.cue`/`.m3u` for discs; multi-disc games grouped by `.m3u`.
- **Covers**: from `thumbnails.libretro.com/<System>/Named_Boxarts/<exact No-Intro name>.png`, cached locally. Title screen and gameplay shots for the panel hero.
- **BIOS**: each core's `.info` lists the files and their MD5. Cartouche checks RetroArch's `system` folder and says exactly what is missing: "Missing: scph5501.bin. Dump it from your own console." No download links, ever.

## In the app

- Sidebar section **Consoles**: one entry per system with games (NES, SNES, PlayStation…), with the system's count.
- Covers in the same grid as PC games: same favorites, search, Play button.
- Game panel: core (recommended + others that support the file), BIOS status, save states found for this ROM, play time (from RetroArch's runtime logs), shader (None, CRT, LCD).
- **Play** launches `RetroArch -L <core> "<rom>" -f --appendconfig <cartouche.cfg>`. Activity shows "Playing"; Quit sends `QUIT` over the network command, then terminates if needed.
- Standalone emulators (Dolphin, PCSX2, PPSSPP, Azahar, xemu…) plug into the same model later: each is an "emulator" with launch arguments, like ES-DE's `es_systems.xml`.

## Legal line

Cartouche plays files the user already has. It never links to ROM or BIOS sites, never ships BIOS, and the UI says "your own game dumps".

## Open questions for the P12 spec

- Default core per system (the research file's "Best pick per system" is the starting point).
- Do we import RetroArch playlists only, or also write them back so RetroArch's own menu stays in sync?
- Controller mapping: rely on RetroArch's autoconfig, or expose a mapping screen?
