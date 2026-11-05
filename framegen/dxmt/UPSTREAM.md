# d3d11: expose the Metal texture and event behind D3D11 objects

Draft of a pull request to [3Shain/dxmt](https://github.com/3Shain/dxmt). Not submitted.
License of the change: LGPL-2.1-or-later, as DXMT's main branch.

Files here:

| File | Base |
|---|---|
| `0001-GetMetalTexture.patch` | `v0.80` (589adb7), the release Cartouche ships; built and tested |
| `0001-GetMetalTexture-main.patch` | `main` at 3b25259 (2026-10-27); same change, rebased, compile-checked |

## Summary

A new device extension, `IMTLD3D11DeviceExt1` (extends `IMTLD3D11DeviceExt`), with two methods:

```cpp
DEFINE_COM_INTERFACE("137ce045-283f-4481-b939-f47233523d22", IMTLD3D11DeviceExt1) : public IMTLD3D11DeviceExt {
  virtual HRESULT STDMETHODCALLTYPE GetMetalTexture(ID3D11Resource *pResource, UINT64 *pTexture) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetMetalSharedEvent(ID3D11Fence *pFence, UINT64 *pSharedEvent) = 0;
};
```

- `GetMetalTexture` returns the `id<MTLTexture>` currently backing a texture resource. Buffers
  and null arguments give `E_INVALIDARG`.
- `GetMetalSharedEvent` returns the `id<MTLSharedEvent>` of a fence made by
  `ID3D11Device5::CreateFence`.

## Why

Native Metal code that runs in the game's process (an upscaler such as MetalFX, a frame
interpolator, a capture or debugging tool) has no way today to reach the textures a D3D11 game
renders. The only exit is a copy to a staging resource and a CPU map, which stalls the GPU and
adds a frame of latency. DXMT's own `TemporalUpscale` already shows the need: it takes D3D11
resources and hands their Metal textures to MetalFX inside `d3d11.dll`. This extension lets code
outside `d3d11.dll` do the same, without knowing DXMT's class layout.

## Ordering

No new synchronisation API: the standard D3D11 fence does it.

1. The game signals the fence to `N` after the work that writes the inputs
   (`ID3D11DeviceContext4::Signal`, which DXMT already encodes as `encodeSignalEvent` and flushes).
2. The native side encodes `encodeWaitForEvent(N)` on its own queue, does its work, then
   `encodeSignalEvent(N + 1)`, and commits. No CPU wait.
3. The game calls `ID3D11DeviceContext4::Wait(N + 1)` before the work that reads the outputs.

## Contract and limits

- Handles are unretained `id` pointers (DXMT's `obj_handle_t`), valid while the D3D11 object
  lives. Retain them to keep them longer.
- The texture is the one backing the resource at the time of the call. A `D3D11_USAGE_DYNAMIC`
  resource may change backing on `Map(WRITE_DISCARD)`: ask again after each map. Default-usage
  resources (render targets, depth, UAVs) keep theirs.
- Hazard tracking for the texture is the caller's job, through the fence above.
- Texture usage follows the D3D11 bind flags: a native pass that writes needs the resource
  created with `D3D11_BIND_UNORDERED_ACCESS` (`MTLTextureUsageShaderWrite`).

## Testing

In a D3D11 test scene under Wine on the `v0.80` patch, with Apple M4, macOS 27:

- the Metal textures behind a colour target (`RGBA8Unorm`), a depth buffer (`R32_TYPELESS`
  → `Depth32Float`), motion vectors (`R16G16_FLOAT` → `RG16Float`) and a UAV output hold the same
  texels as the game's own staging copies, hashed on both sides each frame;
- MetalFX's temporal scaler then a compute pass, encoded on a separate queue and ordered by the
  fence as above, replace the scene's upscale with no copy.

See `framegen/tests/d3d11/dxmt.sh` in Cartouche (`make framegen-dxmt`).
