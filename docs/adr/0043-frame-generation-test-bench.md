# 0043. Frame generation is measured on our own scenes, in our own Wine

## Status

Accepted, 2026-10-27. Implemented (cb453e08, baef63c0, b62c94bb, 079e88bf, 8c3460c6).

## Context

Frame generation quality, cost and pacing need numbers that can be reproduced. The user owns no DLSS game. Real games vary too much between runs (the AMD sample: 36 to 67 fps base with the same settings) to rank small changes.

## Decision

- `make framegen-tune`: a Metal 3D scene with true motion and depth, scored against the true middle frame. It reports `ghost%` (pixels more than 24 levels off), `2x2%` (the same on 2×2 averages, less sensitive to aliasing) and a HUD-region score. It also includes:
  - the depth bench (`TUNE_DEPTH`);
  - pair export (`TUNE_PAIRS`) and offline motion import (`TUNE_MOTION`), to score other estimators.
- `make framegen-tests`: pipeline checks on a 1080p frame pair, plus a Cocoa stand-in game for activation, pause, failure, resize and pacing against native.
- `make framegen-wine`: a Direct3D 11 scene cross-built with mingw-w64 and run in Cartouche's prepared Wine roots. It checks:
  - DXMT and D3DMetal;
  - GPU jitter;
  - a `dlss` mode through DXMT's `nvngx.dll`;
  - the Neural Engine path.
- AMD's FidelityFX SDK sample (MIT; Sponza, D3D12, D3DMetal) is the heavy GPU-bound case, run by hand.
- Every run can write a per-second CSV (`CARTOUCHE_FRAMEGEN_STATS=1`).

## Alternatives rejected

- Judging by eye in real games only.
- NVIDIA's DLSS sample: it is released as source only and needs Visual Studio to build.

## Consequences

Each decision in ADRs 0039 to 0042 cites these measurements. Real-game reports remain the acceptance gate before frame generation leaves the experimental setting.
