# Proposal

## Why

Today the app is a status and setup panel. Cartouche needs the library from the mockup: every game in one place, with what it takes to play it, in a native macOS 26 design that also works on macOS 15.

## What Changes

- SwiftUI library window: sidebar with Library (All Games, Favorites), PC (Steam, Epic, GOG, Amazon, Windows Installers) and Consoles (filled by P13), cover grid, game panel, toolbar with search and Add Games.
- Steam library import read from Steam's own local files (installed games, play data, collections, the account). The `steam-library.json` export from the injected Steam UI code is not in v0.1.0 (maintainer decision 2026-10-19); the app keeps the reader for when that writer lands.
- Favorites, search, hidden games, context menu, menu bar menus and status item, Settings window.
- Every screen state from `mockup/AUDIT.md`: loading, empty, offline, expired session, errors.
- Liquid Glass on macOS 26, standard materials on macOS 15, reduced motion and reduced transparency honored.
- The game model, grid and panel handle PC games (2:3 covers) and console games (square covers) from the start, so P13 only adds data and its panel.
- Non-goals: Epic, GOG, Amazon data (P10); console data and panel (P13); downloads and notifications (P7); FPS (P8).
- Depends on P0; reads runners through the P1 registry.

## Capabilities

### New Capabilities
- `game-library`: what the library shows, how games are found, organized, searched and opened.

### Modified Capabilities
- None.

## Impact

New SwiftUI views in `app/` and a library store. APPFLOW and DESIGN docs. No `dylib/` change: the Steam UI export hook is not in v0.1.0.
