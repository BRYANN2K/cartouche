# qa/world — QA fixture-world generator

`make_world.py` builds a **complete fake user home** under a directory you
choose. Point Cartouche at it (`HOME=<dir>`, or the QA launch flag) and the
whole app can run with **no real network service, no real
Steam/CrossOver/GPTK/RetroArch install, and no change to your real home**.

## Run

```sh
python3 qa/world/make_world.py <dir> --profile <profile>
python3 qa/world/make_world.py <dir> --force          # rebuild over an existing dir
python3 qa/world/make_world.py <dir> --profile senior --damage
python3 qa/world/make_world.py <dir> --profile senior --stale
python3 qa/world/test_make_world.py                   # unittests
```

The build is **deterministic**: fixed content, fixed timestamps, no randomness
or network. Rebuilding the same profile in the same location produces a
byte-identical tree. A non-empty `<dir>` is refused unless `--force` is given,
so a scratch dir can never be silently merged with real files.

## Profiles

| profile    | What exists                                                            |
|------------|------------------------------------------------------------------------|
| `empty`    | Nothing but the `cartouche-world.json` manifest.                        |
| `beginner` | Lived-in home, but **nothing to find** — no Steam, runners, or ROMs.   |
| `medium`   | Steam + 8 games + ROMs + a Downloads installer + the pinned `wine-stable-11.0_1` runner ready. |
| `retro`    | `medium` plus the console library added (gb, gba, ps1, snes), the ROM folder watched, save states with a picture. |
| `senior`   | `retro` plus CrossOver.app, GPTK, a copied `gptk-3.0` runner and a fake `Dolphin.app`. |
| +`--damage`| On medium/retro/senior: adds a **damaged** runner clone and a **corrupt** compat cache — the `broken` world. |
| +`--stale` | On medium/retro/senior: the compat cache stays valid but `generated` is 4 days back — the `offline` world's stale data. |

## What gets built

- **Fake Steam** — `Applications/Steam.app`, `Library/Application
  Support/Steam` with `loginusers.vdf` (player42), `libraryfolders.vdf`
  (two libraries), 8 `appmanifest_*.acf` (6 installed, 1 downloading,
  1 tool), `appinfo.vdf` (v29 binary), `localconfig.vdf`, cloud-storage
  JSON, PNG covers, and `steam-library.json` export.
- **Fake runners** — every Steam world gets the manifest-pinned
  `wine-stable-11.0_1` installed with a verifying receipt. Senior adds
  `CrossOver.app` with the `lib/wine` marker, `Game Porting Toolkit.app`
  with `D3DMetal.framework` (v3.0), a copied `gptk-3.0` runner, and a
  `Dolphin.app` under `~/Applications` the standalone-emulator detector
  finds. `--damage` adds a `crossover-26.3.0.39832` clone with `lib/wine`
  but **no loader** so the registry reports it damaged.
- **`~/Games/ROMs`** — Game Boy, GBA and SNES homebrew carts with valid
  headers (same bytes as the P13 test fixtures), a `.m3u` two-disc PS1
  set, and one unknown `mystery.iso`.
- **`~/Downloads`** — `Disco Elysium (Offline Installer) v1.0.4` with
  `setup.exe`, `data-01.bin`, `data-02.bin`, `unarc.dll`, and
  `MD5/checksums.md5` listing an optional **missing** `data-03.bin`
  (matches the P6 synthetic format).
- **Cartouche support state** — `consoles.json`, `folders.json`,
  `library.json`, `cores.json` + fake dylibs, `.rdb` database files,
  `states/<core>/` save states with `.png` pictures (retro, senior), the
  compat cache (fresh, `--stale` aged, or `--damage` corrupt), and
  preferences under `dev.bryann2k.cartouche.plist`.

`cartouche-world.json` at the root records the profile and what was written.

## Covered / not covered

Covered: every file the app's **readers and detectors** parse — Steam
manifests and VDFs, appinfo v29, runner detection markers, cartridge headers,
playlist/dedup behavior, installer manifests, compat cache (including the
corrupt path), console library state.

Not covered: real binaries (all executables are stubs), real code signing or
Gatekeeper state, network services, Keychain, and anything outside the
scratch home (e.g. `/Applications` at the real root — the runner roots under
the fake home only).
