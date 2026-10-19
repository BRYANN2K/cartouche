# Cartouche roadmap

One scope. Every phase below is built before the first public release, **v0.1.0**. Versions then follow 0.x until the maintainer declares 1.0.

Each phase is one OpenSpec change in `openspec/changes/`. A phase is done when every scenario of its specs has evidence, the review passed, and the change is archived.

## Phases

| Phase | Change | Goal | Depends on |
|---|---|---|---|
| P0 | `p0-rebrand-cartouche` | The fork becomes Cartouche and can live next to NotProton | – |
| P1 | `p1-runner-model` | One runner model instead of CrossOver-only code | P0 |
| P2 | `p2-free-runners` | Wine CrossOver built from CodeWeavers' sources, WineHQ and GPTK as runners | P1 |
| P3 | `p3-graphics-backends` | D3DMetal, DXMT, DXVK, wined3d per game; Mac or Windows version | P2 |
| P4 | `p4-compatibility-data` | Nightly compatibility JSON and the per-Mac estimate | P0 |
| P5 | `p5-library-app` | The SwiftUI library, built for PC and console games, covers, every state | P0 (P1 interface) |
| P6 | `p6-windows-installer` | Install from a Windows installer, end to end, with game and cover matching | P1, InstallerKit |
| P7 | `p7-downloads-activity` | Activity slot, notifications, the cover reveal shader in Metal | P5, P6 |
| P8 | `p8-performance-tracking` | FPS measured per session and per setup | P3 |
| P9 | `p9-release-pipeline` | CI, free signing, Sparkle updates, Homebrew tap, upstream watch | P0 |
| P10 | `p10-store-integrations` | Epic, GOG and Amazon through legendary, gogdl, nile | P5, P6 |
| P11 | `p11-agent-control` | MCP server for agents: PC, console and controls tools | P5, P6, P8 (P13, P15 for their tools) |
| P12 | `p12-retroarch-bundle` | RetroArch built from source, embedded, driven over MCP; cores and BIOS | P0 |
| P13 | `p13-console-library` | Consoles in the library: add consoles and games, covers, panel, Continue From, launch | P5, P12 |
| P14 | `p14-console-extras` | Netplay, RetroAchievements, translation, iCloud saves, Coach mode | P13 |
| P15 | `p15-controls` | Controller status, remapping, Mac keyboard and mouse, couch mode | P5, P6, P13 |
| P16 | `p16-standalone-emulators` | Dolphin, PCSX2, PPSSPP, Azahar, xemu, Ryubing detected and launched | P13 |
| P17 | `p17-mac-permissions` | Every macOS permission asked at the right moment, explained, recoverable | P0 |
| P18 | `p18-onboarding` | First launch: install, Gatekeeper, detection, choices, permissions | P5, P17 |

## Waves (what runs in parallel)

```
Wave 1  P0                              (running)
Wave 2  P1   P4   P9   P12  P17
Wave 3  P2   P5
Wave 4  P3   P6   P13
Wave 5  P7   P8   P14  P16  P18
Wave 6  P10  P15
Wave 7  P11                             → v0.1.0
```

Two phases run in parallel only when they touch different directories. Each runs in its own git worktree and branch `phase/<change-id>`. Inside `app/`, phases of the same wave own separate folders (for example `Library/`, `Installer/`, `Consoles/`, `Permissions/`).

## Release v0.1.0

- Everything above, with every scenario evidenced.
- Signed with the project's self-signed certificate, distributed through GitHub Releases and the Homebrew tap, updated by Sparkle.
- Release notes say what works and what is experimental (Coach mode).

## After v0.1.0

### v0.1.1
- **Share your stats.** Opt-in sharing of a game's play stats (FPS per setup, runner, backend, Mac model) from the game panel. Off by default; PRIVACY.md lists every field before it ships. Builds on P8's sharing payload, which v0.1.0 keeps in code but hides.
- **Game list on the website.** cartouche.bryann2k.dev lists games with the stars users gave them and the shared stats behind them. The site reads the shared reports; the app never needs an account.
