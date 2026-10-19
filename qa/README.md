# Cartouche QA harness

Run the app against fakes: a throwaway HOME with a synthetic Steam/ROMs/runner
world, and one local mock server for every remote service. Nothing real is
touched — no network, no account, nothing outside `scratch/`.

```sh
qa/launch.sh <profile>            # clean steam stores retro full offline broken
qa/launch.sh offline --port 8891  # QA_PORT also works
```

`launch.sh` builds `out/Cartouche-QA.app` (`make qa-app`), mints a scratch HOME
under `scratch/` with `qa/world/make_world.py`, starts `qa/mocks/server.py`,
then launches the app with `HOME`, `CFFIXED_USER_HOME` and
`CARTOUCHE_QA_BASE_URL` set. It prints the mock's `__control` URL and the pids
to `kill`.

## Profiles and mock scenarios

| `launch.sh` profile | World | Mock scenarios armed |
|---|---|---|
| `clean` | `empty` | — |
| `steam` | `medium` | — |
| `stores` | `medium` | — (store tokens can't be planted — Keychain) |
| `retro` | `retro` | — |
| `full` | `senior` | `controller-dualsense` |
| `offline` | `senior --stale` | `net-down`, `controller-dualsense` |
| `broken` | `senior --damage` | `controller-dualsense`, `store-token-expired:epic`, `crash-missing-dll`, `installer-fail-unarc` |

Every row a persona should try is in `qa/scenarios.md` (do/expect, spec source,
world + mock to use). Arm mock scenarios live:
`curl -X POST http://127.0.0.1:8890/__control/<name>` — `GET /__control` lists
them; `qa/mocks/README.md` documents the routes.

## Safety

- QA mode is compiled into **debug builds only** (`#if DEBUG`). The release app
  ignores `CARTOUCHE_QA_BASE_URL` entirely — never reads it.
- The app only writes under the scratch home. `launch.sh` refuses to run if the
  scratch dir is not a fresh `scratch/qa-home-*` dir.
- The world is synthetic: generated homebrew files and fake manifests, nothing
  downloaded, nothing real.

## How QA mode works in the app

`app/Sources/NotProtonApp/Support/QAEnvironment.swift` re-points every fetched
URL to `$CARTOUCHE_QA_BASE_URL` keeping the path, and lets pinned downloads
also accept the sha256s in `<base>/__pins.json`. Covered: Sparkle feed (and
the compat/runner feeds derived from it), all pinned downloads, MacGamingDB,
Steam CDN/installer, winetricks, libretro buildbot/thumbnails/database.
Not covered: real binaries (all stubs), Keychain, real signing, the mount step
of dmgs — see `qa/mocks/README.md` and `qa/world/README.md`.

## Adding a new endpoint

1. Write the production `https://` URL once, wrap the fetch in
   `QAEnvironment.url(...)`.
2. `QAEnvironmentTests.noLiteralBypassesHelper` scans all sources and fails on
   unrouted literals; display-only links go on `allowedLiterals` with a reason.
3. Teach the mock the route (`qa/mocks/`), add hashes to `__pins.json` fixtures
   for pinned downloads.

## Files

| File | What it is |
|---|---|
| `scenarios.md` | Scenario checklist by screen; defines the profile/mock contract |
| `personas/{beginner,medium,senior}.md` | Maya, Dan, Priya — the three testers |
| `report-template.md` | Findings table + narrative + coverage |
| `world/make_world.py` | Deterministic scratch-HOME generator |
| `mocks/server.py` | All external services + `__control` on 127.0.0.1 |
| `reports/` | Generated reports, transcripts, `shots/` |
