# Frame generation

Experimental 2× frame generation for Wine games on Metal backends (DXMT, D3DMetal). Opt-in per game. Decisions: ADRs 0038 to 0044. Research and measurements: `docs/research/frame-gen-v2/` in the main checkout.

## How it works

```text
game (Wine, x86_64, Rosetta)
  │ presentDrawable / present                  hooks: framegen/framegen.m
  ▼
FGPresenter (present thread)
  ├─ capture: copy the real frame, luma, pyramid, stillness count        fg_pipeline.m
  ├─ motion, the first source available:
  │    1. the game's own (MetalFX or MTL4FX temporal scaler inputs)     ADR 0039
  │    2. the Neural Engine helper's flow (CARTOUCHE_FRAMEGEN_ANE=1)     ADR 0042
  │    3. GPU estimate: luma pyramid, forward and backward check
  ├─ MTLFXFrameInterpolator, at half size from 1280 px wide             ADR 0038, 0040
  ├─ repair pass (6 candidates, softmax) and stillness mask              ADR 0040
  └─ present generated then real, paced by measured latency              ADR 0041
```

### Components

| File | Role |
|---|---|
| `framegen/framegen.m` | Library entry: hooks, present thread, pacing, stats CSV, live settings, engine-data hooks |
| `framegen/fg_pipeline.m/.h` | GPU pipeline: capture, motion estimate, MetalFX, repair, stillness, cuts |
| `framegen/kernels.metal` | Compute kernels, embedded in the library and compiled at launch |
| `framegen/fg_ane.m/.h` | Starts the Neural Engine helper and shares IOSurfaces with it |
| `framegen/ane/helper.m` | `framegen-ane`, the arm64 helper running Core ML on the ANE |
| `framegen/ane/fg_ane_protocol.h` | What the library and the helper share |
| `framegen/fg_temporal.m/.h` | DLSS through MetalFX taken over, on DXMT (MTLFX) and, only with `CARTOUCHE_FRAMEGEN_TEMPORAL4=1`, on an MTL4FX scaler as D3DMetal may make one: the game's temporal scaler tuned as it is made, the shared RCAS (`FGSharpen`, upscale.metal) on its output with a reversible tone map for float colour, an optional reactive mask. On an MTL4 command buffer our passes take a residency set of ours, an argument table, queue barriers on both sides and the scaler's fence when it has one (`FGSharpen4`, the same kernel). `FGTemporalScaler` is the scaler the game encodes (MTLFX or MTL4FX); its textures are the game's last encode, its output holds the sharpened frame once the game's command buffer has run |
| `framegen/fg_bridge.m` | The library's end of the Wine bridge: a ring and a real-time reader |
| `framegen/bridge/` | The Wine bridge: `cartouche_bridge.dll` (PE builtin, mingw) and `cartouche_bridge.so` (its unix half), and what they share with the library |
| `framegen/ane/convert_rife.py` | Converts Practical-RIFE 4.25.lite to `framegen-flow.mlmodelc` |

### Neural Engine path

1. At start, the library spawns `framegen-ane` (arm64), found next to the library, with a clean environment and the service name `dev.cartouche.framegen.ane.<pid>`.
2. It looks the service up, then sends four IOSurfaces (two input frames, flow, mask) and the name of a shared control page.
3. For each real frame, the GPU writes the frame at 512×256, planar FP16, into the next input slot.
4. Once the frame before is in the other slot, the library bumps `request` and waits on `done` with `os_sync_wait_on_address`, for at most `ane_wait_ms`.
5. The helper runs the network with output backings on the shared surfaces, then sets `done`.
6. The `ane_motion` kernel turns the flows into the interpolator's motion. On timeout, the GPU estimate serves that frame.
7. The helper exits when the library sets `quit` or when the game's process goes away.

### Zero-copy D3D11 path (DXMT, tests only)

DXMT patched with `framegen/dxmt/0001-GetMetalTexture.patch` (LGPL-2.1-or-later, kept apart from our code) exposes `IMTLD3D11DeviceExt1`: `GetMetalTexture` gives the `MTLTexture` behind a D3D11 resource, `GetMetalSharedEvent` the `MTLSharedEvent` behind an `ID3D11Fence`.

1. The game side gets the handles once, then each frame signals the fence to `N` after its rendering (`ID3D11DeviceContext4::Signal`).
2. It hands the handles to the library through the Wine bridge (`cartouche_bridge_metal`, one synchronous call).
3. The library waits for `N` on its own queue, runs MetalFX's temporal scaler then RCAS into the game's output texture, signals `N + 1` and commits. No CPU wait.
4. The game waits for `N + 1` (`ID3D11DeviceContext4::Wait`) before it reads the output.

`framegen/dxmt/build.sh` builds the patched `d3d11.dll` from the pinned v0.80 source in `~/Library/Caches/cartouche-fg-dxmt` and clones Cartouche's DXMT Wine root around it. The user's DXMT is never touched. Off by default; nothing in the app uses it yet.

### FFX proxy (tests only, off by default)

`framegen/proxy/ffx_proxy.c` stands in for a game's `amd_fidelityfx_loader_dx12.dll` or `amd_fidelityfx_dx12.dll` as a Wine builtin. It exists only when `WINEDLLPATH` points at `out/framegen/proxy` and `WINEDLLOVERRIDES=amd_fidelityfx_loader_dx12=b`; nothing in the app sets either. It loads AMD's DLL from the game's folder through a renamed copy in the prefix's `%TEMP%` (the game's folder is never written), forwards the five calls unchanged and logs them to the library. Written from AMD's MIT headers only (`framegen/proxy/ffx`).

- `CARTOUCHE_FFX_COPY=1`: each frame's depth and motion are copied into readback buffers in the game's own command list and handed to the library once the GPU is done (`fg_proxy.m`); `2` adds the upscaler's output (tests). The game's thread never waits: a busy slot skips the copy, a copy whose fence does not pass in 2 s is dropped.
- `CARTOUCHE_FFX_FG`: unset or `game`, the game's FSR frame generation runs and the library stands down; `ours`, AMD's stays off and the library's replaces it; `force` (tests) turns AMD's on whatever the game says.
- `CARTOUCHE_FFX_UI=1` (tests): the proxy sits between AMD's swapchain and the game's present callback, to copy each frame without and with its UI.
- `CARTOUCHE_FFX_LOG_ALL=1` logs every call; `CARTOUCHE_FFX_REAL` names AMD's DLL when it is not beside the game.
- Library side: the vectors are matched to the real frame by the game's frame number, taken at present. Under D3DMetal they land 15 to 30 ms after the present: a frame takes its own when they are there, else the newest at most two frames older. `CARTOUCHE_FRAMEGEN_FFX_WAIT=<ms>` waits for its own instead (0). Vectors with NaN or longer than the frame, past 0.2 % of the pixels, or a reset, refuse the frame and our estimate serves. The depth is kept, unused for now (ADR 0040).
- Tests: `CARTOUCHE_FRAMEGEN_FFX_DUMP=<dir>` writes frames `_DUMP_FROM` (1) to `_DUMP_FROM + _DUMP_COUNT` (8): motion in pixels and depth as floats, the upscaler's output, and with `CARTOUCHE_FFX_UI=1` each real frame without and with its UI (`tests/ffx/score.m` reads them).
- `make framegen-ffx` runs AMD's FSR sample (FidelityFX SDK v2.3.0, `FRAMEGEN_FFX_SAMPLE`) on D3DMetal without then with the proxy.

## Settings

Environment variables, read at launch:

| Variable | Effect |
|---|---|
| `CARTOUCHE_FRAMEGEN=1` | Loads the library for this launch. Cartouche sets it from the game's profile: temporal upscaling (our chain on the game's MetalFX scaler) or the HUD on, on D3DMetal or DXMT, never for a protected game |
| `CARTOUCHE_FRAMEGEN_INTERPOLATE=0` | No generated frames: the temporal chain stays, the presents are taken only for the HUD, metrics or stats, with no pacing, no gating and no copies; with none of them, they are left alone. Cartouche's launches (`compat_run.sh`, an installed game's launcher) always set it, and a setup file cannot. Unset, as in the tests, generation is on |
| `CARTOUCHE_FRAMEGEN_STATS=1` | Writes `framegen-<time>-<pid>.csv`, one row per second |
| `CARTOUCHE_FRAMEGEN_DIR` | Folder for the CSV (default `/tmp`) |
| `CARTOUCHE_FRAMEGEN_ANE=1` | Uses the Neural Engine helper, with RIFE lean (`framegen-flow.mlmodelc`) |
| `CARTOUCHE_FRAMEGEN_ANE=fg1` | Same, with Cartouche FG 1, our own network (`framegen-flow-fg1.mlmodelc`, `make out/framegen-flow-fg1.mlmodelc`); `a6` is an old alias |
| `CARTOUCHE_FRAMEGEN_ANE_HELPER`, `_ANE_MODEL` | Helper and model paths, if not next to the library |
| `CARTOUCHE_FRAMEGEN_TUNE="name=value,…"` | Any live setting below, from the start |
| `CARTOUCHE_FRAMEGEN_TEMPORAL="name=value,…"` | The game's temporal scaler (DLSS on DXMT, or MTL4FX under D3DMetal): `sharpness` (RCAS stops, default 0.25, negative off), `jitter`, `exposure`, `mv_jittered`, `reactive`, `bounds`; `off` or `0` leaves the runner's chain as it is. Accepted in a game's setup file (`setups/<appid>.env`) and passed to the game by `compat_run.sh`. `jitter` is a factor on the game's jitter; `exposure` 1 MetalFX's own, 0 the game's, -1 as made; `mv_jittered` the game's vectors carry its jitter (macOS 27); `reactive` the strength of a mask where colour changes that motion does not explain (0 off); `bounds` 1 the scale fixed at the render size's, -1 no dynamic resolution, 0 as made. Tests only: `fx=1` times an interpolator of its own after the scaler, `fx=2` one made on the scaler |
| `CARTOUCHE_FRAMEGEN_TEMPORAL4=1` | Opts our chain into an MTL4FX temporal scaler (DLSS under D3DMetal), never run on a real game yet: without it the scaler is left as made, no tuning, no kernels, no Metal 4 resources, byte for byte |
| `CARTOUCHE_FRAMEGEN_FRONT=1` | Tests only: brings the game window to the front (macOS drops frames of hidden windows) |
| `CARTOUCHE_FRAMEGEN_FAIL=kernels\|drawable` | Tests only: forces a failure |
| `CARTOUCHE_FRAMEGEN_PROBE_LOG=<file>` | Tests only: when each generated frame was shown, and its centre pixel |
| `CARTOUCHE_FRAMEGEN_UPSCALE=chain\|metalfx\|bilinear[+rcas[=stops]]` | Shows a game that renders below the screen's pixels (Wine without Retina mode, or a lower in-game resolution) at the screen's size, in a layer of ours over the game's: `chain` is CMAA2 then MetalFX's spatial scaler; `cmaa2`, `metalfx`, `bilinear`, `rcas` combine with `+`. With `TUNE=enabled=0`, upscaling alone |
| `CARTOUCHE_FRAMEGEN_DUMP=<file.ppm>[:first[:every]]` | Tests only: the shown image of real frame `first` (and every `every`-th after), `%ld` in the name for the frame number |
| `CARTOUCHE_FRAMEGEN_CLICKS="x,y;…"` | Tests only: left clicks posted to the game's window from inside the process, 2 s after the upscale layer is up, at shares of the layer |

Live settings (`CARTOUCHE_FRAMEGEN_TUNE` or the test window):

| Name | Default | Meaning |
|---|---|---|
| `enabled` | 1 | 0 presents real frames only, with stats |
| `estimator` | 1 | 0 block matching, 1 luma pyramid |
| `factor` | auto | Analysis at 1/factor of the frame (about 1000 px wide) |
| `check` | 1 | Forward/backward agreement: 1 full search back, 2 short one, 0 off |
| `downscale` | auto | MetalFX at 1/downscale: 2 from 1280 px wide |
| `repair` | 1 | Repair pass after MetalFX |
| `hud` | 4 | Frames a pixel must stay unchanged to be copied from the real frame; 0 off |
| `engine` | 1 | Use the game's motion when its upscaler hands it over |
| `cuts` | 1 | A scene cut repeats the frame before |
| `follow` | 1 | Pacing follows measured latency |
| `cushion_ms` | 1 | Latency held above half an interval |
| `aim` | 0.97 | Fixed pacing aim when `follow=0` |
| `ane` | 1 | Use the helper when it is running |
| `ane_wait_ms` | 6 | Longest wait for the helper's flow |

## Stats CSV

Columns: `time, render_fps, presented_fps, gpu_ms, gpu_max_ms, interval_ms, interval_sd_ms, refresh_ms, paused, dropped, sd_floor_ms, long_intervals, one_refresh, two_refresh, three_refresh, four_plus_refresh, generated_wait_max_ms, admit_wait_max_ms, latency_ms, confidence_mean, repaired_pct, ane_pct, ane_ms`.

- `sd_floor_ms`: the lowest deviation a fixed refresh allows for this rate, `refresh·√(f(1−f))`.
- `long_intervals`: intervals longer than the output period rounded up to whole refreshes.
- `gpu_ms`: the library's own command buffer, interpolation included.
- `ane_pct`: share of frames whose flow came from the helper in time.

## Build and test

| Command | What it does |
|---|---|
| `make framegen` | The library (x86_64) |
| `make framegen-ane` | The helper (arm64) |
| `make out/framegen-flow.mlmodelc FRAMEGEN_PYTHON=…` | Converts RIFE; needs coremltools and torch, plus `RIFE_DIR` and `RIFE_REPO` |
| `make framegen-tests` | Pipeline checks at 1080p, then the Cocoa stand-in game: activation, MTL4, pause, failures, resize, pacing against native |
| `make framegen-temporal4` | Our DLSS chain on an MTL4FX temporal scaler in MTL4 command buffers (853×480 → 1280×720, Halton jitter): the scaler left as made by default, image against the full-size render beside MTL4FX alone once opted in, GPU per frame, with the scaler's fence, with an RGBA16Float output, and the kill switch byte for byte |
| `make framegen-wine` | D3D11 scene in Cartouche's Wine on DXMT and D3DMetal, GPU jitter, ANE path, DLSS engine motion, our DLSS chain against DXMT's (PSNR and SSIM against the full-size render, GPU per frame) |
| `make framegen-temporal` | GPU cost of our chain around a temporal scaler made as DXMT makes one, without Wine |
| `make framegen-bridge` | The Wine bridge in the D3D11 scene on DXMT: 10 000 frames, loss and one-way latency, load order against a game's DLL of the same name |
| `make framegen-dxmt` | Builds the patched DXMT in a scratch dir, then in the D3D11 scene: the Metal texture behind colour, depth, motion and output against the scene's own copies; our MetalFX chain in place of the upscale, scored against a 2x reference and timed |
| `make framegen-tune` | Settings search on the 2D and 3D scenes, scored against the true middle frame |
| `make framegen-test` | Interactive test window with live settings |
| `make framegencheck` | The launch script's side |
| `make framegen-mfx` | MetalFX's interpolator alone on a moving square: implicit instant, scaled vectors, descriptor options, cost |
| `make framegen-latency` | Relative click-to-photon latency on the stand-in game: off, capped, hooks only, 2x (`FRAMEGEN_CLICKS`, `FRAMEGEN_BASES`, `LATENCY_DIR`); `latency_pool.sh` pools runs |
| `make framegen-upscale` | Upscaling on the stand-in game at half resolution and in Wine (DXMT, D3DMetal): clicks against the marks the game draws, one layer size, 2x on top, MTL4, failure |
| `make framegen-upbench` | The spatial chain's parts against a 3x3 supersampled truth (PSNR, SSIM, >24 levels), on the 3D scene with and without texture filtering, and their GPU cost (`UPBENCH_DUMP`; `out/framegen/score` scores PPM frames, the one scorer for files) |
| `make framegen-fxboth` | A temporal scaler and an interpolator: apart, and with the interpolator made on the scaler |
| `make framegen-watts` | Energy per shown frame from `powermetrics` (run `sudo -v` first); `WATTS_THROTTLE=1` adds 20 minutes |

`tune` options: `--3d`, `TUNE_SET`, `TUNE_DUMP`, `TUNE_DEPTH` (depth bench), `TUNE_HUD` (HUD-region score), `TUNE_REPAIR` (repair thresholds), `TUNE_ROW`, `TUNE_PAIRS` (export frames), `TUNE_MOTION` (import motion), `TUNE_MFX=b|c|e|f` (MetalFX questions: other instants, 4x by recursion, UI kept apart against `keep_still`, no previous colour), `TUNE_HUD_MARGIN`, `TUNE_KIND` (with `e`).

## Measured (MacBook Air M4, macOS 27, 144 Hz external display)

| Measure | Value |
|---|---|
| GPU per generated frame, 1080p (pipeline bench) | 6.4 ms (9.4 with MetalFX at full size) |
| GPU per generated frame, 720p, D3D11 scene in Wine | 4.8 ms; 3.7 ms with the ANE |
| 3D scene, 2×2 blocks wrong, 72/40 fps | 3.9/8.4 % estimated; 3.5/7.1 % ANE flow; 1.7/3.0 % game motion |
| Without repair (estimated) | 8.5/21.5 % |
| Pacing at 40→80 fps | 1.4-2.4 long intervals/s, against 4.8-7.8 for native 80 fps |
| ANE flow, 512×256 | 2.1 ms back to back, 3.4 ms p50 and 4.8 ms p95 at game cadence |
| Latency, D3D11 scene | about 15 ms; about 20 ms with the ANE |
| DLSS on DXMT, D3D11 scene 853×480→1280×720, Halton jitter, against the full-size render | DXMT 32.46 dB, SSIM 0.9345; ours (RCAS 0.25) 32.83 dB, SSIM 0.9455; +0.09 ms GPU |
| Wine bridge, 10 000 frames, one way | 7.5 µs p50, 21.5 µs p99, none lost; the game's call 4.5 µs p50, 31 µs p99 |

## Limits and open work

- 2× only, with a base rate of 29 fps or more. 60→120 fps is tight with the ANE path.
- MetalFX frame interpolation needs macOS 26 or later.
- HUD: a game's final frame has no separate UI, so `keep_still` keeps still pixels from the last real frame. When a source keeps the UI apart (`FGPipeline.uiTexture`, the FSR FG proxy later), the UI goes on top after the repair pass, on macOS 27. It is the UI alone in premultiplied alpha, or with `uiComposited` the final frame while the captures are the same frame without UI; `encodeCapture:` copies it, so the source may reuse its texture. Without it, or on macOS 26, `keep_still` handles the HUD. MetalFX's own `uiTexture` adds nothing then: the repair pass rebuilds from frames without UI.
- The D3DMetal engine-data path (MetalFX and MTL4FX) and runner frame-generation detection have been checked in the stand-in game only, not with a real game.
- Store games launched through `/usr/bin/arch` lose the insertion variable.
- Open: payload staging of `framegen-ane` and the model, a launcher allowlist for `CARTOUCHE_FRAMEGEN_ANE`, a Cartouche-trained network (smaller and with clean data), the region scene-cut detector, real-game reports.
