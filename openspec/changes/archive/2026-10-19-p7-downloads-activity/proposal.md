# Proposal

## Why

Long operations (Steam downloads, installs, runner updates, running games) need one calm place to watch them and a signal when they end, without keeping a window open.

## What Changes

- The activity area at the bottom of the sidebar: running game with Quit, install, downloads with an App Store style ring, updates.
- macOS notifications when a download or install finishes, with an action.
- The cover reveal shader, ported to Metal, while a game downloads or installs.
- Non-goals: Cartouche's own downloader for Steam games (Steam downloads them); store downloads (P10).
- Console sessions from P13 use the same activity slot ("Playing on RetroArch", Quit).
- Depends on P5 and P6.

## Capabilities

### New Capabilities
- `activity`: how ongoing work is shown, controlled and announced.

### Modified Capabilities
- None.

## Impact

Sidebar activity view, notification center integration, a Metal shader for covers. Steam download progress read from Steam's download state.
