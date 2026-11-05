# CI optimization of the public repositories

Written 2026-11-02. Nothing here was pushed, run, re-run, cancelled or changed on
GitHub: every branch below is local and waits for review.

**Key point.** Hosted minutes cost 0 USD on public repositories, so the real
cost is waiting time. It sits in two places: `cartouche-wine` rebuilds Wine for
changes that do not touch Wine, and Cartouche's app job has never finished green.

## How this was measured

- Source: every run and job on `gh api`, 2026-11-02, for the 14 public repositories.
- "Minutes" are the sum of job durations. The billing endpoint needs a scope the
  token does not have, and it was not requested.
- Cache hit rates come from run logs. Today every repository holds 0 cache
  entries: GitHub evicts entries after 7 days without access.
- Every gain below is an **estimate** unless it says "measured". ccache and the
  new job layout have never run, so their timings are forecasts.

## Current cost

| Repository | Runs | Period | macOS min | Windows min | Linux min | Total | Failed | Reruns |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `cartouche-wine` | 17 | 20–22 Oct | 688 | 0 | 1 | 688 | 13 | 0 |
| `maestro` | 101 | 3 Aug – 2 Nov | 20 | 39 | 418 | 477 | 26 of 53 | 1 |
| `cartouche` | 31 | 24–25 Oct | 221 | 0 | 12 | 233 | 26 | 0 |
| `stipulate-skills` | 22 | 12 Aug – 11 Oct | 74 | 0 | 62 | 136 | 0 | 0 |
| `promethee-pomodoro` | 12 | 26–28 Aug | 9 | 7 | 3 | 19 | 8 | 0 |
| `BRYANN2K` | 90 | 11 Aug – 2 Nov | 0 | 0 | 14 | 14 | 0 | 0 |
| `promethee-mcp` | 11 | 28 Aug | 0 | 0 | 8 | 8 | 1 | 0 |
| `llm-engineering-benchmark` | 11 | 13–15 Aug | 0 | 0 | 2 | 2 | 2 | 0 |

- `maestro`'s 53 excludes the 48 internal Dependabot jobs.
- `homebrew-cartouche`, `OpenClean`, `NotProton`, `open-design`, `modlens` and
  `layout-autoswitch` have no workflow and no run: nothing to optimize.
- `cartouche-site` is not public, so it is out of scope.

## `cartouche-wine`

Branch `ci/optimize`, based on local `main`, so it carries your unpushed fix
150f966 (`libgstreamer-1.0.0.dylib`). The next Wine build needs that fix anyway.

### Where the 688 minutes went (measured)

| Phase | Minutes | Share |
|---|---:|---:|
| `Build` (of which compile about 37 per run, configure 2) | 508 | 74% |
| Boot check | 68 | 10% |
| `Package` (`xz -9e`, 6 to 10 per run) | 57 | 8% |
| Verify and scan | 28 | 4% |
| Everything else | 26 | 4% |

- A real run takes **60 to 82 minutes**, not the "3–5 h" `docs/ci-github-actions.md`
  estimated. The GStreamer stage adds about 9 minutes on top since 26.3.0-3.
- **13 of 17 runs failed**, and 3 were cancelled. Only 1 succeeded.
- 9 runs compiled all of Wine, then failed on a later step: 6 on the boot check,
  1 on `check-dlopen`, 1 on packaging, 1 on a network fetch of gettext.

### Top wastes

1. **Rebuilding for boot script changes.** Before the runs of 21 Oct 23:38,
   22 Oct 01:12, 02:35 and 07:17, the only file changed was `boot-check.sh`, yet
   each compiled Wine again. They cost 286 minutes, of which 44 were the boot. The
   07:17 run published the release, so it needed its build. The other 3 cost 215.
2. **No compile cache.** Each of the 10 full compiles started from zero, on
   identical CodeWeavers sources.
3. **Maximum compression on test builds.** `xz -9e` runs on builds nobody ships.

### Changes

| Commit | Change | Measured basis | Expected gain (estimate) |
|---|---|---|---|
| `49651bc` | ccache on builds that do not publish, with PRs unable to reach it | 10 full compiles, 453 min; 37 min of compile per run | Rebuild `Build` step from 40–50 to about 12–20 min, so 25–30 min per retry. First run is cold. |
| `1f491c4` | `boot` is its own job, and a `boot_only_run` input tests an old artifact | 3 avoidable runs, 215 min, of which 28 boot | 60–82 min becomes 8–18 min per boot iteration: about **180 min** of the 688 (26%) |
| `ad44a10` | `xz -6` on builds that do not publish | `Package` 6–10 min per run | 4–6 min per run |
| `92d3395` | Timeout 300 to 180 min | Slowest run 82 min, plus 9 for GStreamer | Nothing on a normal run; a hang costs 2 h less |

Combined, a burst like 20–22 October would cost about **300 to 350 minutes
instead of 688** (estimate): 180 from boot-only runs, about 135 from ccache on 5
retries, about 40 from `xz -6`. A publishing run stays at about 85 to 90 minutes.

### Safety of these changes

- **A published build never touches ccache.** `publish: true` compiles from
  scratch with `-9e`, exactly as today, and a test now enforces it. Cached objects
  can only reach test builds, so a poisoned cache cannot reach a release.
- **The build job never runs on pull requests**, so a PR cannot save or read the cache.
- `boot_only_run` cannot publish: `publish` needs `build`, which is skipped.
- `boot` reads artifacts of this repository only and uses no secret.
- The cache key names the toolchain pins, because ccache hashes llvm-mingw's
  wrapper rather than the real compiler.
- No check is removed. Verify, the redistribution scan and the boot check all still run.

### Considered and rejected

- Shallow clones: the repository is 213 KB.
- Path filters and concurrency: already right. Full builds are dispatch-only and
  PRs run only the 0.9-minute `scripts` job.
- Matrix pruning and schedules: there is no matrix and no schedule.
- Caching Homebrew: `brew install` takes 0.3 minutes.
- Caching the GStreamer install tree: ccache covers most of it, with one mechanism
  instead of two.

## `cartouche`

Commits are on the existing `BRYANN2K/ci-github-actions` branch, after 11818f8b.
Actions is still disabled there, so everything below is unproven until cutover.

### Measured

- 15 real `app` runs averaged **14.7 minutes** (10.9 to 30.9), and **none passed**.
- All 15 failed at `Run the hermetic C suites`, on `fpscheck`: 5 to 8 failed
  assertions in 12 runs, an abort (exit 134) in 3. The count varies between runs.
- So `Run the Swift tests`, `Run the InstallerKit tests` and the bundle scan have
  **never run on Actions**. Their cost is unknown and is the main open question.
- Fonts rebuilt on every run, 3.5 minutes on average, because the old `actions/cache`
  never saves on a failed job. 11818f8b already fixed that.

### Changes

| Commit | Change | Measured basis | Expected gain (estimate) |
|---|---|---|---|
| `dc3f7d8c` | C suites run before fonts and `make app`, after the cache saves | 7.8 min on average spent before they failed, 15 runs, 118 min | A red run fails about **8 min sooner**. No gain on green. |
| `5c6555ea` | Fonts key names `FONT_TOOLS`, not the hash of `app.yml` | 3.5 min per font rebuild | 3.5 min after each `app.yml` edit |
| `981593bc` | No Homebrew update or cleanup in `app` | Brew steps 0.46 min per run | About 0.2 min per run |
| `75875e5b` | Cancel superseded RetroArch runs on PRs | Up to 6 macOS jobs of up to 60 min, no concurrency group before | Frees macOS slots. Not measured: RetroArch never got past startup. |
| `1719842e` | `docs/ci-github-actions.md` corrected with measured durations | 60–82 min, not 3–5 h | None, accuracy only |

`dc3f7d8c` was checked by reading: the suites build scratch fixtures and do not read
`out/Cartouche.app`, fonts or the payload. The first run confirms it.

### Considered and rejected

- SwiftPM `.build` cache: checkout resets file times, so SwiftPM likely recompiles
  anyway. Measure after the first green run.
- Partial clone of Dobby: under 15 seconds.

## `maestro`

Branch `ci/optimize`. Most of its 477 minutes are Linux, and the Go cache already
hits at 73 MB (run log).

| Commit | Change | Measured basis | Expected gain |
|---|---|---|---|
| `184d51e` | PRs restore the Go cache and never save it | `setup-go` also saves on PRs, and it has no restore-only mode | Safety only, 0 min. One cold run while the new key seeds. |

- Failures here are real: 11 of 14 PRs fail `govulncheck` on the Go standard
  library. That is the check working, not waste (decision 7).
- Merging the 6 cross-compile jobs was rejected: 3.6 job-minutes become about 2.5,
  but the wall clock goes from 0.7 to over 2 minutes.

## `stipulate-skills`

Branch `ci/optimize`.

| Commit | Change | Measured basis | Expected gain |
|---|---|---|---|
| `8b73956` | Pin actions by SHA | 3 unpinned actions | Safety |
| `85e62d3` | `contents: read`, cancel superseded PR runs | No `permissions`, no concurrency group; 0 PR runs so far | 0 min measured |

The cost is the suite itself: 2.5 minutes serial, on 8 matrix jobs (decision 6).

## `promethee-pomodoro`, `promethee-mcp`

Branch `ci/optimize` on both.

| Commit | Change | Measured basis | Expected gain |
|---|---|---|---|
| `26baf6d` (pomodoro), `6e9f222` (mcp) | PRs skip `setup-node`'s npm cache, which also saves | `cache: npm` on `pull_request` | Safety. PRs about 15 s slower (estimate). |

## `llm-engineering-benchmark`

Branch `ci/optimize`.

| Commit | Change | Measured basis | Expected gain |
|---|---|---|---|
| `fd39af8` | Pin checkout by SHA | Unpinned action | Safety |
| `a097996` | Cancel superseded PR runs | No concurrency group; 0 PR runs so far | 0 min measured |

## `BRYANN2K`

No change. 90 runs at 0.15 minutes, already pinned, least privilege and scheduled on purpose.

## Decisions for you

Each one removes or narrows a check, or changes a rule, so none was applied.

1. **`fpscheck` on hosted runners.** It blocks the whole app job. It runs a Metal
   test app, which may not work on a hosted VM, and its failure count moves from run
   to run. The cause is not proven. Recommended: read its failures on the first run,
   then skip only GPU-bound assertions if that is the cause. Skipping narrows a
   check, so it is your call.
2. **Sparkle key on a hosted runner.** `runner-manifest.yml` signs with
   `SPARKLE_PRIVATE_KEY`, which breaks your rule. Today the repository has 0
   environments and no secret, and the workflow has never run, so nothing is
   exposed. Recommended: sign on the Mac and never create that secret.
3. **Boot check on the Intel image.** It costs 16 minutes per run and ends in
   `env-cannot-boot`, because that image cannot boot a prefix. Recommended: try one
   dispatch with the variable `WINE_BOOT_RUNNER=macos-15` (arm64 with Rosetta).
   Whether Rosetta works there is unverified. If it fails, keep it as is.
4. **Docs-only pushes in Cartouche.** 44 of the last 298 commits (15%) touch only
   Markdown, and each runs the full macOS job. Recommended: skip `app` for those and
   keep every Linux job, including the redistribution scan.
5. **RetroArch's second build.** Two 60-minute builds on every PR that touches it.
   Recommended: run the second on push and dispatch only. It narrows the
   reproducibility check on PRs.
6. **`stipulate-skills` matrix.** 3 Python versions on 2 systems. Recommended: run
   only the oldest and newest Python on macOS, which cuts 1 macOS job of 6 test jobs
   per push.
7. **`maestro` Go version.** Recommended: bump the Go toolchain so `govulncheck`
   passes, which clears the failures on 11 of 14 PRs.
8. **Duplicate Wine workflow.** Cartouche's `wine-crossover.yml` is an older copy of
   the `cartouche-wine` one. Recommended: delete it from Cartouche before enabling
   Actions.
9. **Linux jobs on Actions.** The migration moves Linux jobs too, while your notes
   from 31 October keep them on Woodpecker k3s. Recommended: confirm which one holds.

## Next step

Review `ci/optimize` on `cartouche-wine` first, then dispatch one build on `main`
twice: the first seeds ccache, and the second's job summary shows the real hit rate.
