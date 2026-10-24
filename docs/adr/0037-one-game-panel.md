# 0037. One game panel, fixed module order

## Status

Accepted, 2026-10-23. The order is implemented on `fix/0.1.0-mac-validation` and covered by the panel tests. A live check of five games is still open.

## Context

The PC column and the console page used different chrome and different orders. Setup, Your Play and Continue From moved with the game. A missing block either left a hole or made the blocks under it jump.

## Decision

PC games and console games share one panel. The top is the artwork (172 pt; the Steam carousel when the game has a store id; a CRT or LCD overlay only on a console), the title, and one metadata line. That line is source, status and size, separated by middle dots. Size is omitted when it is unknown. A console line is the console name, a middle dot and the play state, with no trailing period.

Modules come from `PanelModules` and do not trade places. A module that does not apply is omitted and leaves no empty card. The exception is Your Play on an installed PC game with no session: the card stays and reads "No sessions yet".

PC order: Play, then Setup and Your Play only when the game is installed, then Expected on This Mac, Anti-Cheat when a summary exists, Graphics Reported on Macs when a layer has reports, Advanced when the resolved Windows runner has an option, then Controls. A download and a store's first-launch boot replace the Play row in place.

RetroArch order: Play, BIOS when firmware is missing, Continue From when a save state exists, Setup, Your Play, Controls, Play Together, More…. Setup holds the core, the look, discs, input lag and Hardcore. Your Play holds play time and achievements.

A standalone emulator uses Play, Setup, Your Play, Controls and More…. It has no BIOS alert, no Continue From and no Play Together.

Advanced stays its own disclosure. It is not wrapped in a second card. Controls keeps its owner: Cartouche, Steam Input or RetroArch.

## Alternatives rejected

- A separate console page with its own order.
- Hiding Your Play on an installed PC game until the first session.
- An empty card for every module the game does not have.

## Consequences

`GamePanel` owns the scroll view, the hero and the console sheets. `ConsolePanel` only lays out console modules. New panel content is a module in `PanelModules`, in the order above, or it stays behind Details or More….
