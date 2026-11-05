# 0039. Use the game's own motion when its upscaler goes through MetalFX

## Status

Accepted, 2026-10-27. Implemented for DXMT (b62c94bb). The D3DMetal path is untested: it needs a real DLSS game.

## Context

Games that use DLSS, FSR or XeSS hand their upscaler real depth, motion vectors and jitter. Under DXMT with `DXMT_ENABLE_NVEXT=1`, DLSS super resolution becomes a MetalFX temporal scaler call inside the game process, where Cartouche's library runs. The Game Porting Toolkit licence forbids decompiling or disassembling D3DMetal (section 2D).

## Decision

- The library swizzles `-[MTLFXTemporalScalerDescriptor newTemporalScalerWithDevice:]`, then `encodeToCommandBuffer:` on the concrete scaler class. At each encode it copies the motion texture in the same command buffer, into one of two textures in turn.
- When a fresh copy exists and the `engine` setting is on (default), the interpolator gets that motion, resampled, in place of the estimate.
- A `newFrameInterpolatorWithDevice:` call that is not Cartouche's own means the runner already generates frames. Cartouche's generation then turns itself off (`framegen: disabled runner-fg`).
- Only public MetalFX API calls in the game's own process are observed. No runner binary is read or patched.

## Alternatives rejected

- A clean-room FSR 3.1 or Streamline shim on the Windows side. No bridge from `ID3D12Resource` to `MTLTexture` is known, and a shim DLL is visible to anti-cheat.
- OptiScaler as a separate GPL DLL. It is unsupported on macOS and DX12 only.
- Patching DXMT (LGPL on main). That means maintaining a fork. Upstream interest exists (DXMT issue #71) and may be revisited.

## Consequences

On the 3D test scene, true motion with the repair pass leaves 3.0 % of 2×2 blocks wrong at 40 fps, against 8.9 % for the estimate. The D3D11 test scene has a `dlss` mode that calls DXMT's `nvngx.dll`, so the path is tested without a DLSS game. Depth is not used (ADR 0040).
