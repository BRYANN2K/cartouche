# Cartouche QA mock server

One local HTTP server standing in for **every external service Cartouche
calls**, with recorded-looking data for the same 8 Steam games the app tests
use (Elden Ring 1245620, Counter-Strike 2 730, Apex Legends 1172470,
Red Dead Redemption 2 1174180, God of War 1593500, Cyberpunk 2077 1091500,
Baldur's Gate 3 1086940, Hollow Knight 367520).

```sh
python3 qa/mocks/server.py --port 8890     # binds 127.0.0.1 only
python3 -m unittest discover -s qa/mocks   # 64 route/scenario tests
```

The server prints `QA control: http://127.0.0.1:<port>/__control` at start.

## How the app reaches it

Routes match the **paths** of the real services, so the QA harness points each
base URL at the mock (all injectable in the app today):

| App knob | Real value | QA value |
|---|---|---|
| `SUFeedURL` (Info.plist) | `github.com/.../releases/latest/download/appcast.xml` | `http://127.0.0.1:8890/releases/latest/download/appcast.xml` |
| `MacGamingDBClient.api` | `https://macgamingdb.app/api/rest/games/` | `http://127.0.0.1:8890/api/rest/games/` |
| `CoreSource.buildbot` | `buildbot.libretro.com` URLs | `http://127.0.0.1:8890/nightly/apple/osx/arm64/latest/` + `/assets/frontend/info.zip` |
| `DatabaseSource.libretro` | `raw.githubusercontent.com/.../rdb/` | `http://127.0.0.1:8890/rdb/` |
| `Thumbnails.base` | `https://thumbnails.libretro.com/` | `http://127.0.0.1:8890/` |
| Steam CDN bases | `*.steamstatic.com`, `*.akamaihd.net`, `media.steampowered.com` | same paths on the mock |

**Pinned downloads** (runners.json, backends.json, valve-packages.manifest,
the appcast's own URLs) keep their `https://github.com/…` addresses — manifest
validation requires that host — so the QA harness maps `github.com` (and the
CDN hosts above) to the mock: /etc/hosts in the QA jail or a URL-protocol
override in the QA build. Every asset also answers on its github.com *path*:
`GET /BRYANN2K/NotProton/releases/download/<tag>/<file>`.

## `__control` — scenario switch

`GET /__control` lists every scenario name; `POST /__control/<name>` arms one;
`DELETE /__control/<name>` disarms it; `POST /__control/clear` resets all;
`POST /__control/reset-fetch` clears the request log and per-run counters
(the once-a-day limit lives app-side); `GET /__control/requests` returns the
request log; `GET /__control/state` dumps armed flags for the other QA fakes.

All names from `qa/scenarios.md` are accepted. Names whose effect lives in
another fake (fake Steam, fake TCC, the QA home) are **recorded** and visible
in `/__control/state` — `steam-*`, `homebrew-*`, `installer-*`,
`crash-missing-dll`, `fps-session`, `injection-blocked`, `bios-*`,
`icloud-synced-state`, `controller-*`, `perm-*`, `agent-pending-approval`,
`onboarding-reset`. The rest act directly on the routes below:

| Scenario | Effect on this server |
|---|---|
| `net-down` / `offline` | every external route → 503; `__control` still answers |
| `slow` | every external route waits 3 s |
| `corrupt-download` | archives (release assets, cores, Valve zips) serve corrupted bytes — same length, wrong SHA-256 |
| `empty-library` | lists empty; MacGamingDB 404; thumbnails/covers 404; compat records `{}` |
| `compat-stale` | `compat.json.gz` is 40 days old, sources `stale` |
| `compat-corrupt` | `compat.json.gz` is gzipped JSON but schema-invalid |
| `macgamingdb-down` | `/api/rest/games/*` → 503 |
| `store-token-expired:<epic\|gog\|amazon>` | that store's routes → 401 |
| `download-running:<appid>` / `download-done:<appid>` | recorded in `/__control/state.downloads` |
| `update-available` | appcast offers 0.2.0 (app is 0.1.0) |
| `update-foreign-key` | the 0.2.0 item carries a foreign EdDSA signature |
| `beta-available` | appcast adds 0.2.0-beta.1 tagged `<sparkle:channel>beta` |
| `ra-no-mcp` | `RetroArch_Metal.dmg` serves the `NO-MCP` marker build |
| `ra-hardcore` | RetroAchievements answers mark hardcore active |
| `netplay-lobby` | `/lobby/` lists a friend's SNES game |

## Routes and the app feature they serve

| Route | Serves | App feature |
|---|---|---|
| `/api/rest/games/{appid}` | recorded `macgamingdb-1245620.json` + generated reports (chip, method, layer, rating, fps, settings) per fixture game | compatibility-data: live Mac reports, per-Mac estimate |
| `/api/rest/games/9990001` | 200, `reviews: []` | "No reports yet for this version" |
| `/api/rest/games/9990002` | 500 | cache-fallback path |
| `…/releases/download/compat-data/compat.json.gz` | gzipped nightly compat file: tools' recorded fixture + generated records so all 8 games appear; schema-valid | compatibility-data: offline compat cache, game panel |
| `…/releases/download/compat-data/runners.json` | runner manifest, revision 2 — bundled wine builds unchanged + `wine-crossover-26.3.0-1` pinned to the fake archive's real SHA-256 | runner-sources: manifest refresh, "Wine CrossOver 26.3 → ready" |
| `…/releases/download/compat-data/backends.json` | backend manifest with QA pins for the fake DXMT/DXVK archives | **to verify** — the app reads only its bundled backends.json today (UPD-04) |
| `…/releases/latest/download/appcast.xml` | Sparkle feed: stable item always; update/beta/foreign-key per scenario | release-pipeline: Sparkle updates |
| `…/releases/download/{tag}/{asset}` | tiny real archives: wine `tar.xz` (with `root/loader` tree), `dxmt-*.tar.gz`, `dxvk-*.tar.gz`, `Cartouche-*.zip` | runner-management, game-setup backend downloads |
| `…/releases/download/…/*tampered*` | corrupted bytes always | damaged-download refusal |
| `/nightly/apple/osx/arm64/latest/{core}_libretro.dylib.zip` | zip with one stub Mach-O dylib | retroarch-runtime: core download/check |
| `/assets/frontend/info.zip` | `*_libretro.info` for every catalog core, incl. BIOS names + MD5s | retroarch-runtime: extensions + BIOS status |
| `/stable/{v}/apple/osx/universal/RetroArch_Metal.dmg` | placeholder dmg bytes (not mountable) | retroarch-runtime: official-version picker |
| `/rdb/{System}.rdb` | libretro-db wire format from `data/libretro-rows.json` (SNES, Game Boy, PlayStation) | console-library: identification by checksum/serial |
| `/{System}/{Named_Boxarts\|Named_Titles\|Named_Snaps}/{name}.png` | generated PNG covers | console-library: covers |
| `/store_item_assets/steam/apps/{appid}/{kind}.jpg` | generated PNG (JPEG magic also accepted by `looksLikeImage`) for `library_600x900`, `library_hero`, `library_capsule` | game-library: covers; installer identify |
| `/client/installer/steam.dmg` | placeholder dmg (not mountable — QA plants Steam.app) | onboarding / Install Steam |
| `/{pkg}.zip.{sha1}` and `/client/{pkg}.zip.{sha1}` | tiny zips for `valve-packages.manifest` names; **hashes can't match the real Valve pins** — QA overrides the bundled manifest or plants the fake Steam | steam-shim repair/install |
| `/ISteamChartsService/GetMostPlayedGames/v1/` | recorded `steam-most-played.json` | tools/compat builder (not the app) |
| `/w/api.php` | `generator=embeddedin` → `agw-listing.json`; `pageids=` → `agw-content.json` filtered | tools/compat builder |
| `/repos/bdefore/protondb-data/contents/reports` | recorded listing | tools/compat builder |
| `…/reports_{mon}{d}_{yyyy}.tar.gz` | tar.gz holding `reports_piiremoved.json` | tools/compat builder |
| `…/AreWeAntiCheatYet/master/games.json` | recorded games.json | tools/compat builder |
| `/Winetricks/winetricks/{rev}/src` | stub shell script | game-setup verb installs |
| `/stores/{epic,gog,amazon}/games` `/stores/{store}/status` | `data/stores/*.json` fixtures | **P10, to verify after merge** — store-integrations |
| `/retroachievements/dorequest.php?r=…` | login2 / gameid / patch / achievementcounts | **P14, to verify after merge** — console-extras RetroAchievements |
| `/lobby/`, `/lobby/list` | `{rooms: []}` or the friend's room | **P14, to verify after merge** — console-extras Netplay |

## What is NOT covered

- **Real archive contents**: stub Mach-Os and stub DLLs verify hashes and zip
  layout, but cannot run. Runner/backend *install* works end-to-end for the
  QA-pinned build; actually launching a game needs the fake Steam/runner world.
- **Real pins**: wine/DXVK/DXMT/Valve assets can't match the bundled SHA-256s
  (impossible by design). QA either downloads the QA-added `wine-crossover`
  build (verifies for real) or the QA build overrides the manifests —
  that override is the harness's job, documented in `qa/scenarios.md`.
- **Sparkle signatures**: the appcast carries placeholder edSignatures; an
  end-to-end signed update needs the real EdDSA keypair, which the mock can't
  hold. `update-foreign-key` is still fully testable (refusal is the point).
- **Steam's own API**: the library comes from the fake Steam's local files in
  the QA home, not HTTP — nothing to mock there beyond the CDN and installer.
- **Store/RA/lobby wire shapes**: P10/P14 are unmerged; fixtures match their
  design docs and are marked *to verify* — see `data/stores/*.json` headers.
- `steam.dmg` and `RetroArch_Metal.dmg` are placeholders: hdiutil can't mount
  them, so the download-Steam and official-RetroArch-install flows are
  covered up to the mount step.

## Files

```
qa/mocks/
  server.py          the server (stdlib only)
  fixtures.py        payload builders
  test_server.py     unittest, 62 tests
  data/              recorded files (MacGamingDB, AGW, ProtonDB, AWaCY,
                     steam charts, libretro rows, .info files, stores/)
```
