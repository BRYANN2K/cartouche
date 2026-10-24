# Upscaling and frame generation for Windows games on Apple Silicon

**Research status (verified 2026-10-21):** Verified against CodeWeavers CrossOver 26 support documentation, official changelog, Apple Developer docs, upstream DXMT docs/source, and locally built CrossOver 26.3 source artifact at `/tmp/cx-art`. Exact UI mappings are stated only where the public source supports them; some GUI implementation keys remain proprietary/unverified.

## Findings and implementation implications

CodeWeavers documents Advanced Settings for CrossOver 26 and later. Its DLSS toggle enables “DLSS powered by MetalFX”, only when in-game DLSS is enabled and only with D3DMetal or DXMT. This is a translation/substitution layer, not NVIDIA hardware. No title whitelist or quality-mode control is published. CrossOver changelog/source for 26.3 includes D3DMetal 3.0 and DXMT 0.72; the minimum documented UI version is 26. Exact CrossOver UI env/registry key for DLSS is not given in public support docs. `D3DM_ENABLE_METALFX=1` appears in community GPTK instructions, but its equivalence to CrossOver's UI toggle is unverified; do not assert it as the UI mapping.

DXMT upstream separately documents DLSS Super Resolution → MetalFX Temporal Scaler on Apple Silicon. Its NVIDIA extension path requires `DXMT_ENABLE_NVEXT=1` and DXMT's `nvapi64.dll`/`nvngx.dll` components. Separately, DXMT supports spatial swapchain scaling using `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`; default factor doubles output resolution, adjustable through `d3d11.metalSpatialUpscaleFactor` (1.0–2.0) in config or `DXMT_CONFIG`. These controls are DXMT-specific, not CrossOver UI mappings. DXMT documents Sonoma+ for vendor extensions. Published NV extension support lists DLSS SR, not FG.

FSR and XeSS are title-integrated APIs; their upstream SDK support for DX/Vulkan is not proof of generic Wine/macOS compatibility. OptiScaler is a third-party DLL proxy/mod, not an official Wine/CrossOver capability; game-specific compatibility and anti-cheat risk remain. No Cartouche global upscaler should claim these.

Apple documents MetalFX frame interpolation API availability on macOS 26.0+. The API requires explicit application integration and frame inputs; it is not established as transparent D3DMetal/DXMT support or a system-wide Wine frame-generation toggle. FSR 3 FG is likewise game-integrated and path-dependent. Lossless Scaling is a Windows product; no official macOS implementation or generic LS-like Cartouche FG option was verified. Capture-based overlays are not equivalent to swapchain/compositor integration and can add latency/artifacts.
## Advanced panel recommendation matrix

| Option | Mechanism / exact mapping | Cartouche runner support | Recommendation for game panel “Advanced” |
|---|---|---|---|
| DLSS → MetalFX | CrossOver UI: officially described, exact UI env/registry key not publicly documented. Requires in-game DLSS and D3DMetal or DXMT. DXMT-native NV extension requires `DXMT_ENABLE_NVEXT=1` plus extension DLLs; separate from CrossOver UI. | CrossOver 26+ UI feature; our default CrossOver build is 26.3 (project context). DXMT API may vary by bundled version. | Runner-capability gated toggle, only when CrossOver 26+ and backend D3DMetal/DXMT. Don’t write an invented key or treat `D3DM_ENABLE_METALFX` as verified equivalent. |
| MetalFX spatial | DXMT only: `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`; config `d3d11.metalSpatialUpscaleFactor` 1.0–2.0 (default effective factor 2.0). | DXMT config integration; not generic CrossOver/D3DMetal toggle. | Separate opt-in DXMT control only if Cartouche exposes DXMT env/config. Clearly distinguish output swapchain scaling from game DLSS. |
| AVX2 to Rosetta | CrossOver/Wine env `ROSETTA_ADVERTISE_AVX=1`; advertises AVX capability via CPUID on macOS 15, does not itself implement AVX instructions. | CrossOver 26.3 source contains it; runner/build/OS-dependent. | Show only as compatibility setting with explanation; no AVX2 promise or speed-optimization claim. |
| MSync | `WINEMSYNC=1` enables MSync in CrossOver Wine client/server. CrossOver source warns consistent server/client setting; restart bottle. | CrossOver 26.3 Wine source confirms; not generic runner mapping. | Bottle-scoped toggle, restart whole bottle after change. |
| High Resolution Mode | CrossOver UI turns off pixel doubling and reports 192 DPI. Related Wine key: `HKCU\Software\Wine\Mac Driver` → string `RetinaMode` = `y`/`n`; source verifies RetinaMode but not that it alone reproduces the entire UI behavior. | Wine/CrossOver Mac driver setting, scoped to bottle; exact complete UI mapping unverified. | Toggle with tested CrossOver mapping; do not add guessed `LogPixels` edits as equivalent. |
| Metal HUD | Apple documents `MTL_HUD_ENABLED=1`. CrossOver bottle-local persistence is `[EnvironmentVariables]` in `cxbottle.conf` (setting itself is Apple Metal diagnostics). | Applies only to Metal-rendering process; backend behavior not universally guaranteed. | Optional diagnostics toggle, off by default; use bottle/process env, never global launchctl. |
| FSR / XeSS / OptiScaler | Title integrated or injected mod; no generic launcher env mapping. | Game and renderer-specific; OptiScaler macOS/DXMT unverified. | No global toggles. Manual, per-title documentation only after tests; warn about mod/anti-cheat risk. |
| MetalFX frame interpolation / FSR FG | MetalFX API needs native app integration (macOS 26+); FSR FG needs title integration. No Cartouche generic switch established. | No verified transparent Wine FG support. | Do not add a generic frame generation toggle. |
| Lossless-Scaling-like FG | No official native macOS app or generic WindowServer frame-gen interface verified. | None confirmed. | No promise; capture overlay prototypes are a distinct tradeoff and require separate latency/quality validation. |


## Source register (primary sources)

- CodeWeavers Advanced Settings in CrossOver Mac 26 (settings and backend constraints): https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26
- CodeWeavers CrossOver changelog (26.3 / component version history): https://www.codeweavers.com/crossover/changelog
- CodeWeavers source tarball for CrossOver 26.3.0 (Wine-derived implementation): https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz — local built source metadata at `/tmp/cx-art/wine/wine-crossover-26.3.0-1/SOURCE.md` names this URL and SHA-256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`. Repo artifact is a Wine build from CodeWeavers open source, not all of proprietary CrossOver.
- Apple MetalFX API documentation: https://developer.apple.com/documentation/metalfx
- Apple `MTLFXFrameInterpolator` (macOS 26.0+): https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolator
- Apple WWDC25 MetalFX session: https://developer.apple.com/videos/play/wwdc2025/211/
- DXMT Vendor Extensions (DLSS SR via MetalFX Temporal Scaler; Apple Silicon): https://github.com/3Shain/dxmt/wiki/Vendor-Extensions
- DXMT customization (spatial swapchain env/config): https://github.com/3Shain/dxmt/blob/main/docs/CUSTOMIZATION.md
- DXMT source inspected for NGX feature implementation: https://github.com/3Shain/dxmt/blob/50102f994b406f58f56d5d09f2ad20f9b90390a2/src/nvngx/nvngx.cpp
- Apple Metal HUD developer tech talk (`MTL_HUD_ENABLED`): https://developer.apple.com/videos/play/tech-talks/110339
- AMD FSR 3 documentation: https://gpuopen.com/fidelityfx-super-resolution-3/
- Intel XeSS SDK: https://github.com/intel/xess
- OptiScaler upstream: https://github.com/optiscaler/OptiScaler
- Lossless Scaling publisher listing: https://store.steampowered.com/app/993090/Lossless_Scaling/


**Remaining uncertainty:** CrossOver’s proprietary GUI implementation may write internal settings beyond the public Wine source; the complete High Resolution UI write set and DLSS toggle key were not established. CodeWeavers documents UI options since CrossOver 26; exact first patch release of DLSS toggle was not established. MetalFX frame interpolation is a documented macOS 26 API, but not confirmed usable through Wine’s D3DMetal/DXMT. DXMT features in current upstream docs may differ from the older DXMT 0.72 bundled in CrossOver 26.3; capability detection/testing is required.
