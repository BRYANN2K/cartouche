# 0030. Advanced Windows-game options in the game panel

## Status

Accepted, 2026-10-21; amended by ADR 0031. Product placement is approved; implementation and runtime support depend on research-upscaling.

## Context

Windows-game options should be available from Cartouche’s game panel rather than require users to find them in another runner UI.

## Decision

Add an Advanced section to the game panel for all Windows games, across Steam, other stores and local installer/import sources. It covers CrossOver-style options: DLSS→MetalFX, MetalFX upscaling, AVX2 to Rosetta, MSync, High Resolution and Metal HUD.

Research-upscaling must establish each option’s actual runner/backend/OS requirements and application mechanism. Do not invent environment variables, imply universal runtime support or claim these controls already work. This decision chooses placement and scope, not default values or a confirmed DLSS replacement implementation.

## Alternatives rejected

- Expose these options only for one store or installer games.
- Treat CrossOver’s UI labels as proof of identical support in every Wine build.

## Consequences

The game-setup spec records the planned section. Runtime wiring and eligibility await research. The normal Graphics menu continues to follow ADR 0027.
