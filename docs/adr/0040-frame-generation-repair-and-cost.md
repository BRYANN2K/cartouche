# 0040. Repair MetalFX's frame, protect still pixels, keep depth constant, run MetalFX at half size

## Status

Accepted, 2026-10-27. Implemented (55020031, 636b73d6).

## Context

Measured on the 3D test scene, against the true middle frame:
- Depth has no measurable effect on MetalFX's output: constant, true, ramp and random depth score the same within 0.1 point, with or without the macOS 27 camera matrices.
- Even with true motion, MetalFX leaves 19 % of 2×2 blocks wrong at 40 fps.
- Our estimate is close to true motion, so a better estimator gains 1 to 2 points at most.
- MetalFX itself costs about 4 ms at 1080p on an M4.

## Decision

- **Repair pass** after MetalFX, in two stages (`repair_weights` on analysis luma, `repair_frame` at full size):
  - six candidate vectors per pixel: its own, four neighbours 16 px away, and zero;
  - each candidate scored by the 3×3 photometric agreement it implies between the two real frames, at the midpoint;
  - candidates mixed by a softmax of their costs;
  - MetalFX's pixel replaced where the best cost is low and its colour is far from the mix.
- **Stillness mask**: a pixel unchanged for 4 real frames is copied from the last real frame (`hud=4`). This protects HUDs without a HUD-less frame.
- **Depth** stays constant, and so does the camera. Pseudo-depth and monocular depth on the ANE are dropped.
- **MetalFX at half size** from 1280 px wide; the repair stays at full size.

## Alternatives rejected

- Pseudo-depth from forward/backward flow consistency, and Depth Anything V2 Small on the ANE: there is no gain to buy when depth is ignored.
- Push-pull inpainting where no candidate is trusted: there, MetalFX's own pixel beats a blurred fill.
- A full port of FSR 3's optical flow: it brings no sub-pixel step and no forward/backward check, and the estimator was not the bottleneck.

## Consequences

2×2 blocks wrong on the 3D scene fall from 8.45/21.5 % to 3.9/8.4 % at 72/40 fps. 1080p costs 6.4 ms per generated frame, against 9.4 ms with MetalFX at full size and 8 ms with neither change. The stats CSV reports `confidence_mean` and `repaired_pct`.
