# 0038. Frame generation in the game process, with MetalFX as the interpolator

## Status

Accepted, 2026-10-27. Amends ADR 0031: frame generation is no longer excluded, but it stays an experimental, opt-in setting (`CARTOUCHE_FRAMEGEN=1`) until a real-game report confirms it. Implemented on `phase/frame-gen-prototype` (cb453e08 onward).

## Context

Wine games on Apple silicon often run below the display rate. DLSS frame generation needs NVIDIA hardware, and Lossless Scaling is commercial Windows code that Cartouche cannot embed. macOS 26 added `MTLFXFrameInterpolator`, and the base M4 reports support for it. Most games give us only their final frames: no depth, no motion vectors, no camera.

## Decision

- An x86_64 library inserted into the game's Wine process hooks `CAMetalLayer nextDrawable` and the Metal present calls. It copies each real frame, builds the frame halfway between the last two, and presents generated then real frames from its own present thread.
- MetalFX `MTLFXFrameInterpolator` stays the interpolator. Cartouche's own work feeds it better inputs and repairs its output (ADRs 0039, 0040, 0042).
- Generation is 2× only, pauses below 29 fps base, and falls back to normal presentation on any failure (kernel load, drawable stall, resize error).
- No code, shader, weight or constant from Lossless Scaling, lsfg-vk or the GPL DXMT fork that does interpolation.

## Alternatives rejected

- An external capture app (ScreenCaptureKit plus a separate window), as Lossless Scaling and DraFG do. It adds a capture copy and latency, and cannot see engine data.
- Our own synthesis backend in place of MetalFX. It would cost as much GPU time and would not benefit from Apple's hardware and OS updates.
- VideoToolbox frame processors (`VTLowLatencyFrameInterpolation`, `VTOpticalFlow`). They are refused in x86_64 (Rosetta) processes. Natively, the optical flow costs 9.7 ms at 512×256.

## Consequences

The library ships in the app payload and the launch paths insert it per game. The spec, the test window, `make framegen-tests`, `make framegen-tune` and `make framegen-wine` cover it. Everything above the interpolator is Cartouche's own code and can change without changing MetalFX.
