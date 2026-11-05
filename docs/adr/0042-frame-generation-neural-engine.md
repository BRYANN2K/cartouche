# 0042. Optical flow on the Neural Engine through an arm64 helper

## Status

Accepted, 2026-10-27, as opt-in (`CARTOUCHE_FRAMEGEN_ANE=1`). Implemented (470a4eea). Payload staging, launcher allowlist and the default are open.

## Context

The GPU is the bottleneck in the games that need frame generation, and the motion estimate costs 3 to 5 ms of it at 1080p. Apple silicon's Neural Engine sits idle while games run. Measured on an M4:
- Core ML lists the ANE in x86_64 (Rosetta) processes but falls back to the CPU there: 77 ms.
- In arm64, a Practical-RIFE 4.25.lite flow network converted to Core ML runs fully on the ANE.
- A lean variant (warps at each block's size, the last full-size block removed) takes 2.1 ms at 512×256, with zero-copy IOSurface inputs and outputs.
- At game cadence the ANE takes about 3.4 ms (p50) and 4.8 ms (p95), and up to 14 ms (p95) next to a game that saturates the GPU.

## Decision

- **Process:** the library starts `framegen-ane`, an arm64 executable next to it, with a clean environment.
- **Rendezvous:** they meet on a per-process Mach service (`bootstrap_check_in` / `bootstrap_look_up`). The library sends four IOSurfaces (`IOSurfaceCreateMachPort`) and the name of a shared control page.
- **Per real frame:**
  - the GPU writes the frame at 512×256, planar FP16, into one of two input slots;
  - the helper runs the network and writes the flows to the middle frame, plus a mask, straight into a shared surface;
  - both sides wake each other with `os_sync_wait_on_address` in shared mode.
- **Into MetalFX:** the library turns the flows into the interpolator's motion (later frame → earlier frame, at the later frame's pixels). The repair pass runs on top.
- **Fallback:** an answer later than `ane_wait_ms` (6 ms) means that frame uses the GPU estimate.
- **Model and licence:** Practical-RIFE 4.25.lite, whose weights are declared MIT by its author. A smaller Cartouche-trained network (A6, now Cartouche FG 1) will follow at zero cloud cost, trained on our own synthetic scenes with RIFE as a teacher.

## Alternatives rejected

- Core ML inside the game process: no ANE under Rosetta.
- Vision `VNGenerateOpticalFlowRequest` (21 to 67 ms) and `VTOpticalFlow` (9.7 ms): slower, and unavailable under Rosetta.
- Training on paid cloud GPUs: no budget.
- Private ANE APIs: unstable, and a legal risk.

## Consequences

D3D11 scene at 720p on DXMT: every frame served, 3.1 ms on the ANE, our GPU time from 4.8 to 3.7 ms, about 5 ms more latency. On the 3D test scene, the helper's motion with repair leaves 3.53/7.06 % of 2×2 blocks wrong at 72/40 fps, against 3.92/8.37 % for the GPU estimate. The extra latency fits 40→80 fps but is tight at 60→120 fps. Cutting it is A6's goal.
