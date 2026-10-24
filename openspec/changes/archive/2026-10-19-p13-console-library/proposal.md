# Proposal

## Why

Consoles are a headline feature: a player's console games should sit next to their PC games, look as good, and start as easily. P12 gives Cartouche a RetroArch it controls; this phase is everything the player sees.

## What Changes

- Consoles section in the sidebar: one entry per console the user added, a + to add consoles, right-click to remove one.
- Adding console games: the toolbar + sheet's Console Games tab (drop files or folders) and watched game folders from Settings > Library; identification by checksum against the libretro database; unknown files get a console picker.
- Covers, title screens and screenshots from libretro-thumbnails, cached; square cards.
- Console game panel: Play or Resume, Continue From (save states with their pictures), play time and achievement count, Setup (core, look, input lag, Hardcore, disc), Controls row, BIOS warning, More… for the rest.
- Launch with a CRT power-on, playing state in the activity slot, quit from Cartouche.
- Non-goals: netplay, RetroAchievements sign-in UI, translation, Coach mode (P14); remapping UI (P15).
- Depends on P5 (library) and P12 (RetroArch runtime).

## Capabilities

### New Capabilities
- `console-library`: how console games are added, identified, shown, configured, launched and resumed.

### Modified Capabilities
- None.

## Impact

App views for consoles, a ROM identifier using the libretro database (`.rdb`), a thumbnail cache, folder watching (FSEvents). APPFLOW and DESIGN docs.
