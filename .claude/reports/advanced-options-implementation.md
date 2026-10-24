# Advanced Windows-game options

Implemented capability-gated per-game Advanced section using the existing dark panel styles and per-game setup persistence. All switches default off; spatial factor defaults to 2.0 and clamps to 1.0–2.0. Legacy setups decode without advanced fields.

Mappings: DXMT_ENABLE_NVEXT, DXMT_METALFX_SPATIAL_SWAPCHAIN plus DXMT_CONFIG d3d11.metalSpatialUpscaleFactor; ROSETTA_ADVERTISE_AVX (compatibility advertisement, not speed); WINEMSYNC; RetinaMode string y/n through runner reg; MTL_HUD_ENABLED. Steam uses its existing setup env reader and registry import. Store registry/session work runs detached before game launch; installer launch scripts do the same preparation before exec. MSync changes stop the prefix session on the following launch, not when a toggle changes.

D3DMetal DLSS intentionally hidden: no verified CrossOver 26.3 mapping found. DXMT DLSS offered only when both nvapi64.dll and nvngx.dll exist in the active backend search directory, then staged to system32 with native nvapi64/builtin nvngx overrides. The pinned DXMT archive can omit these optional DLLs; there is no new download or invented support. FEX hides DXMT advanced upscaling and AVX.

Sources checked: research-upscaling; https://raw.githubusercontent.com/3Shain/dxmt/v0.80/docs/CUSTOMIZATION.md ; v0.72 src/d3d11/d3d11_swapchain.cpp confirms spatial env/factor; v0.80 src/nvapi/meson.build (native DLL) and src/nvngx/meson.build (builtin DLL); https://github.com/3Shain/dxmt/wiki/Vendor-Extensions confirms both files/system32 and Apple Silicon.

No frame-generation, FSR, XeSS or OptiScaler toggles. No real Steam/prefix/Library data manipulated; Wine tests use fake executables and scratch folders. Italian, Simplified Chinese and French strings added without changing existing translations.

Validation: native full debug app built successfully; existing GameSetupTests 13/13 passed. settingscheck, backendcheck and envcheck pass. Debug l10ncheck reports pre-existing missing French translations (sessions/performance/installer strings); new entries have all three requested languages. Full l10ncheck target expects Release extraction.
