# Tasks

- [x] Register the WebUI route through the compatsvc route mechanism. (451e393; merged in de0e6ec).
- [x] Generate and rotate a per-launch random token; expose it only to Cartouche’s injected page script. (451e393; merged in de0e6ec).
- [x] Submit the signed-in account’s full owned-games list as SteamExport v1. (451e393; merged in de0e6ec).
- [x] Validate requests and atomically replace steam-library.json without damaging the previous export on failure. (451e393; merged in de0e6ec).
- [x] Preserve account isolation, installed-manifest merging, and play-data-only localconfig handling (main 307ad2c).
- [x] Show the last account-matched export while Steam is closed with a cached/stale label (main 307ad2c).
- [x] Land the follow-up from `fix/steam-compat-tools`: runtime token fetch from `/cartouche/steam-export-token` (no-store, backoff 15 s→300 s) and Steam compatibility tools for Cartouche Wine builds. (Merged in 9214df4 and cb248b2; real Steam evidence is the task below.)
- [ ] Test every scenario in the game-library delta and record fresh evidence.
- [ ] Verify the owned list and refresh in real Steam, including an account switch; obtain review before marking complete.
