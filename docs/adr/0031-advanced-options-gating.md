# 0031. Advanced options gated per runner and backend, no frame generation

## Status

Accepted, 2026-10-21. Amends ADR 0030: it approves the option list and the gating rule. Runtime mechanisms and per-pair eligibility still depend on research-upscaling.

## Context

ADR 0030 approved an Advanced section in the game panel for all Windows games without fixing how each option is offered. Showing every option for every game would imply support that does not exist.

## Decision

The Advanced section has six options: DLSS→MetalFX, MetalFX upscaling, AVX2 to Rosetta, MSync, High Resolution and Metal HUD. Each option is offered only when the game's selected runner and graphics backend support it; the same option may appear for one setup and not for another. No frame-generation option is offered. Research-upscaling establishes which runner and backend pairs each option supports before any control is wired.

## Alternatives rejected

- Offer all six options for every Windows game and let them fail at runtime.
- Add frame generation to the approved set before its mechanism and quality are verified.

## Consequences

The game-setup spec records the gating rule and the fixed option list. Unsupported options are not offered, consistent with the hide-unavailable rule of ADR 0027. Defaults and implementations remain unapproved until research-upscaling reports.
