# 0041. Chained presents whose pace follows the measured latency, judged against native presentation

## Status

Accepted, 2026-10-27. Implemented (fb8b520a, 98a0423f).

## Context

The prototype paced output with `presentDrawable:afterMinimumDuration:`, each present chained to the last, and aimed 3 % faster than the game (`aim=0.97`) so it would never hold the game back. It then ran dry about three times a second, which showed as long intervals. The old test (standard deviation under half a refresh) cannot pass at 40→80 fps on a fixed 144 Hz display: quantisation alone gives `refresh·√(f(1−f))`. The window server also misses refreshes for games that present on their own.

## Decision

- The interpolation is committed to the GPU before waiting for the generated drawable. The blit and the two presents follow in a second command buffer on the same queue.
- `aim` follows the real frames' smoothed latency to the screen, holding it at half an interval plus a 1 ms cushion (`follow=1`). The output rate then matches the game's without a fixed bias.
- Pacing is judged against the same stand-in presenting the doubled rate itself:
  - deviation above the quantisation floor at most 0.5 ms worse;
  - intervals of 3 refreshes or more no more frequent.
- The stats CSV records dropped frames, the floor, long intervals, an interval histogram in refreshes, drawable waits and latency.

## Alternatives rejected

- An output clock with `presentDrawable:atTime:`. In windowed mode the compositor dropped every generated frame when both presents shared a buffer, and 190 to 208 long intervals per 20 s remained otherwise, against 57 chained.
- `CAMetalDisplayLink`, proxy drawables and a pacing thread with per-slot events. They are not needed once pacing beats native presentation, and they risk conflicts with DXMT and D3DMetal drawables.
- A fixed `aim` of 1.0. It halves the hitches but holds the game back (40 to 38 fps) and doubles latency.

## Consequences

At 40→80 fps on 144 Hz: 1.4 to 2.4 long intervals per second, against 4.8 to 7.8 for a native 80 fps present; deviation above the floor 0.3 to 0.7 ms, against 0.9 to 1.4 ms. Under GPU jitter in Wine: 2.3/s against 16.6/s native.
