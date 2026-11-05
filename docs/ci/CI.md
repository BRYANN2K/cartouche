# CI

One workflow gates every pull request and every push to `main`, `dev`, `beta`
and `release/**`: `.github/workflows/ci.yml`. It runs on GitHub-hosted runners
only, reads no secret, and its `required` job passes only when every other job
passed. Releases are not built here: they are signed and published on the
maintainer's Mac (docs/RELEASE.md).

Other workflows run on their own triggers and do not gate merges:
`codeql.yml` (code scanning, see below), `scorecard.yml` (OpenSSF Scorecard, weekly
and on push to `main`), `nightly.yml` (fuzzing, `c-asan`, osv-scanner),
`retroarch.yml` (RetroArch paths), `compat-data.yml` (nightly), `store-clients.yml`
(pins), `upstream-watch.yml` (nightly). `.github/dependabot.yml` opens the update
pull requests. The repository settings these rely on are listed, with the command
for each, in `docs/ci/GITHUB-SETTINGS.md`; none is applied yet.

## Jobs

| Check name | Runner | What it runs | Blocks |
|---|---|---|---|
| `build` | `xcode-27` | `swift build` of `app`, `installer`, `retroarch`; Dobby; `make all overlay-shim fps-counter iconmaker appinfo` | yes |
| `tests` | `xcode-27` | the 24 hermetic C suites, the Python suites, InstallerKit and RetroArchKit tests with coverage; uploads their lcov | yes |
| `coverage` | `ubuntu-latest` | `tools/ci/diff_coverage.py` on the lcov of `tests` and `bundle` | yes |
| `lint` | `ubuntu-latest` | SwiftLint, ruff, shellcheck (`scriptcheck`, `runcheck`), actionlint, `workflow_check.py` | yes |
| `openspec validate` | `ubuntu-latest` | `openspec validate --all --strict` | yes |
| `redistribution scan` | `ubuntu-latest` | `packaging/redist-scan.sh` on the tree, and its planted-file test | yes |
| `bundle` | `xcode-27` | the full app: Wine bridge, innoextract, libarchive, fonts, `make app`, ad hoc signature check, `mincheck`, `l10ncheck`, bundle scan, `Cartouche` artifact, then the app Swift tests with coverage (they read the staged payload) | yes |
| `security` | `ubuntu-latest` | `security/gate.sh --ci --only 10,30,40,45` on the run's range (pull request base, or the previous tip on a push): gitleaks on those commits, actionlint, zizmor (medium+), the self-hosted and signing-material checks, semgrep project rules with `--baseline-commit`, the `45-invariants` greps; the report goes to the run summary and the `security-gate` artifact | yes |
| `c-safety` | `xcode-27` | `make c-asan` (GPU suites skipped, `C_ASAN_GPU=0`), `make c-analyze` (pinned cppcheck, mingw-w64 headers), `make fuzz-regress` | yes |
| `required` | `ubuntu-latest` | fails unless every job above succeeded (a skipped or cancelled job fails it) | yes |

Regression goldens and dependency review are added by their own changes and
join `required` when they land.

### The security job's range

`BASE` is `github.event.pull_request.base.sha` on a pull request and
`github.event.before` on a push. When that commit is missing from the clone
(a new branch, a force push), the gate falls back to its release default, the
last `v0.*` tag. The checkout is full (`fetch-depth: 0`) so both exist. In
`--ci` mode the gate needs no app: the built-app parts of 10, 20 and 70 and the
clang part of 50 report `SKIP`, and 60, 80 and 90 are skipped whole.
`security/gitleaks.toml` accepts one finding, the fake key the gate's selftest
plants, and only in `security/tests/planted-defects.sh`.

## Other workflows

| Workflow | Job (check name) | Runner | Triggers | What it runs |
|---|---|---|---|---|
| `codeql.yml` | `codeql swift` | `macos-26`, Xcode 26.6 selected by path | push to `main`, Mondays 05:41 UTC, manual | traced `swift build` of `app`, `installer`, `retroarch`; `security-extended` queries; fails if the database holds 0 `.swift` files |
| `codeql.yml` | `codeql c-cpp` | `macos-26` | same | Dobby built untraced first, then traced `make all overlay-shim fps-counter fuzz-regress`; fails if 0 C/ObjC/C++ files |
| `codeql.yml` | `codeql actions`, `codeql python` | `ubuntu-latest` | same | `build-mode: none` |
| `scorecard.yml` | `scorecard` | `ubuntu-latest` | push to `main`, Tuesdays 06:17 UTC, manual | OpenSSF Scorecard, SARIF to code scanning, results published (`id-token: write` in that job only) |
| `nightly.yml` | `fuzz <harness>` (10) | `xcode-27` | daily 02:11 UTC, manual (`fuzz_minutes`, 1 to 90, default 30) | `make fuzz-nightly` for one harness; libFuzzer cached on the pinned LLVM commit, the corpus kept between runs; a crash uploads `fuzz-crash-<harness>` |
| `nightly.yml` | `c-asan` | `xcode-27` | same | `make c-asan` |
| `nightly.yml` | `osv-scanner` | `ubuntu-latest` | same | `security/gate.sh --ci --only 20`: osv-scanner over every lockfile, fails on CVSS 7 or more |

CodeQL is not a required check yet. Xcode 27 cannot be traced (GitHub changelog
2026-10-19), and the packages have only ever been built with Xcode 27 here: the
first `codeql swift` run is also the first build with Xcode 26. Make it required
once a run on `main` is green and the extracted-files step shows a real count.
GitHub's default CodeQL setup must stay off, since this workflow replaces it.

`codeql swift` does not run on pull requests: on 2026-11-05 the traced `swift build` of `app` was still running after 90 minutes on the 3-core `macos-26` runner. It runs on `main`, weekly and by hand, with a 240-minute limit. Pull requests still get `codeql c-cpp`, `python` and `actions`, plus the Swift rules of the release gate.

Dependabot (`.github/dependabot.yml`) checks every Monday: GitHub Actions,
SwiftPM in `app`, `installer` and `retroarch`, pip in `tools/ci`
(`requirements-lint.txt`, `requirements-security.txt`) and npm in
`tools/ci/openspec`. Minor and patch updates come grouped, one pull request per
ecosystem, and version updates wait 7 days after a release (`cooldown`).

## Required checks for branch protection

Require these status checks on `main`, `dev`, `beta` and `release/**`, with
names exactly as GitHub shows them for `ci.yml`:

- `required`
- `build`
- `tests`
- `coverage`
- `lint`
- `openspec validate`
- `redistribution scan`
- `bundle`
- `security`
- `c-safety`

`required` alone is enough to block a merge; listing the others as well makes
the failing one visible in the merge box.

## Runner and toolchain

- `xcode-27` is the GitHub-hosted arm64 image with macOS 27 and Xcode 27
  (label declared in `.github/actionlint.yaml`). The October 2026 runs on it
  recorded Xcode 27.0, Swift 6.4 and the macOS 27 SDK; the jobs pin
  `XCODE_APP=/Applications/Xcode_27.0.app`. The packages target macOS 15
  (`platforms: [.macOS("15.0")]`) but are built with the Xcode 27 SDK, as on
  the maintainer's Mac; `swift-tools-version: 6.2` rules out Xcode 16
  (`macos-15`), and Xcode 26 (`macos-26`) was not tried.
- No job uses a self-hosted runner. The old `MACOS_RUNNER` variable is gone,
  so no repository setting can send pull request code to the maintainer's Mac.

## Security model

- `permissions: contents: read` for the whole workflow; no job widens it.
- `permissions: contents: read` in every other workflow too; a job that writes
  says so: `security-events: write` for the CodeQL and Scorecard uploads,
  `id-token: write` for Scorecard only, `issues: write` for `upstream-watch`.
- Every action is pinned by full commit SHA; every downloaded tool by version
  and sha256 (shellcheck, actionlint, SwiftLint in the lint job; gitleaks,
  osv-scanner, zizmor, actionlint and cppcheck's source in
  `tools/ci/install-security-tools.sh`), every Python tool by hash
  (`tools/ci/requirements-lint.txt`, `tools/ci/requirements-security.txt` for
  semgrep), OpenSpec by `tools/ci/openspec/package-lock.json`, the libFuzzer
  sources by LLVM commit and tree hash (`fuzz/build-libfuzzer.sh`). Nothing is
  piped into a shell.
- `persist-credentials: false` on every checkout.
- Caches are restored on pull requests and saved only on push and manual runs.
- No signing identity, Sparkle key, Apple credential or write token exists in
  any workflow. `release.yml` (which named them) and the duplicate
  `wine-crossover.yml` (owned by BRYANN2K/cartouche-wine) were removed.
- Superseded pull request runs are cancelled (`concurrency`); every job has a
  timeout.

## Lint rules

- **SwiftLint** (`.swiftlint.yml`): correctness rules only (`force_try`,
  `force_cast`, `identical_operands`, `unhandled_throwing_task`,
  `discarded_notification_center_observer`, `unowned_variable_capture`,
  `weak_delegate`, `superfluous_disable_command` and others), plus three
  custom rules:
  - `unguarded_remove_item`: `removeItem`/`trashItem` in `Sources/`. Check the
    path is inside the folder it belongs to, then mark the line with
    `// swiftlint:disable:next unguarded_remove_item` and the reason.
  - `try_optional_destructive`: `try?` on `removeItem`, `trashItem`, `moveItem`
    or `replaceItem` in `Sources/`.
  - `http_literal`: a `"http://` literal other than localhost, `127.0.0.1` or
    `[::1]`, in `Sources/`.
  The findings that predate the config (295) are in
  `tools/ci/swiftlint-baseline.json`; only new findings fail. Regenerate it
  only when removing findings: `swiftlint lint --write-baseline tools/ci/swiftlint-baseline.json`.
- **swift-format** is not run: the code does not follow its default style, and
  adopting it means a mass reformat.
- **ruff** (`ruff.toml`): syntax errors, pyflakes, pylint errors, mutable
  defaults, `return` in `finally`, `exec`/`eval`/pickle/unsafe YAML and shell
  injection. No style rules.
- **shellcheck** 0.11.0 on every tracked `.sh` (`make scriptcheck`), except
  `dylib/feats/compat_run.sh` (`make runcheck` owns it) and the zsh benches in
  `docs/research/`.

## Coverage gate

`tools/ci/diff_coverage.py` reads the lcov that `tools/ci/export-coverage.sh`
writes for each package (`llvm-cov export -format=lcov`, Sources only, paths
relative to the repository). It fails when:

- the changed lines are covered below 80%. Changed lines are those the pull
  request adds or edits in `*/Sources/**/*.swift` (`git diff` against the base
  commit), counted only when the compiler instruments them; or
- the total line coverage is more than 0.1 point below
  `tools/ci/coverage-baseline.json`.

On a push the base is the previous tip; a new branch has none, so only the
total is checked. When the total rises more than 0.5 point above the baseline,
the job says so: raise the baseline in the same pull request
(`--write-baseline`). C coverage is not measured.

No maintained action covers lcov diff coverage without a third-party service,
so the gate is this script; `tools/ci/tests/test_diff_coverage.py` tests it.

## Skipped on hosted runners

The `tests` job sets `CARTOUCHE_CI_HOSTED=1` when `runner.environment` is
`github-hosted`. Only these checks read it, each probes the condition first,
and each skip prints `SKIP` (shell) or a cancelled test with its reason
(Swift Testing). Off a hosted runner nothing is skipped.

| Suite | Skipped check | Condition probed | Why |
|---|---|---|---|
| `fpscheck`, `fps-counter-tests` | exact frame counts (60 per second, 60 frames) | `kern.hv_vmm_present` is 1 | a virtual Mac does not pace frames exactly; the game must still present frames |
| `fpscheck`, `fps-counter-tests` | a hardened loader refuses the counter | dyld loads the counter into a hardened copy of the test app | SIP is off on hosted runners, so the hardened runtime does not keep inserted libraries out |
| app and RetroArchKit Swift tests | tests that read drawn text with Vision | `VNRecognizeTextRequest` throws | the recognizer needs the Neural Engine or a real GPU (`e5rtError`) |

RetroArchKit tests that need the built RetroArch, the test core or the network
are skipped by their own traits (`set CARTOUCHE_RETROARCH ...`) and run in
`retroarch.yml`. GPU benches (`framegen-*`, NRD), real games and store logins
never run in CI.

How the shell skips were checked (2026-11-05, on the maintainer's Mac): with
`CARTOUCHE_CI_HOSTED=1`, a fake `sysctl` reporting a virtual machine and a fake
`codesign` that drops `-o runtime`, `fpscheck` printed 3 `SKIP` lines and
`fps-counter-tests` 4; with the same fakes and without the variable,
`fpscheck` failed the 4 hardened-loader assertions that failed on the hosted
runner in October. The Vision cancel has not met a hosted runner yet.

## Red before CI existed

These fail on `release/0.2.0-beta2` itself, so the first `ci` run is red until
each test or the code it checks is fixed. None is skipped or excluded, except
the last, which never ran anywhere.

| Test | Failure |
|---|---|
| RetroArchKit `StandaloneLaunchTests.aRemovedEmulatorFallsBackOrSaysItIsNotInstalled` | expects "Ryubing is not installed" for Switch; the catalog lists Eden first since c1f6440f |
| app `AddMenuTests` (3 expectations) | expects EA last and "Experimental" in the add menu; the menu ends at Ubisoft |
| app `OnboardingFlowTests` "Only the manifest-pinned Cartouche Wine is recommended" (2) | expects `wine-crossover-26.3.0-2`; `runners.json` recommends `wine-crossover-26.3.1` |
| app `LaunchSafetyTests` HUD test (`LaunchSafetyTests.swift:407`) | expects `hudOutside` for a BattlEye game with the library loaded |
| `qa/world/test_make_world.py` `test_medium_installer` | expects "selective" in a fixture that says "optional"; left out of `python-tests` |

## Local results

Replayed on the maintainer's Mac (Xcode 27.0, Swift 6.4) in a fresh clone,
2026-11-05:

| Step | Result |
|---|---|
| build: `swift build` ×3, Dobby, `make all overlay-shim fps-counter iconmaker appinfo` | pass (about 2 min) |
| hermetic C suites (`tools/ci/c-suites.sh`) | 24 of 24 pass, 587 `ok` lines plus 101 packaging unittests, 0 `FAIL` (228 s) |
| `make -s python-tests` | 121 tests pass (47 compat, 7 diff-coverage, 67 QA mocks) |
| InstallerKit | 211 tests pass |
| RetroArchKit | 168 tests, 1 failure (above), rig and network tests skipped by trait |
| app, after the payload is staged | 2069 tests, 6 failures (above), no OCR failure |
| coverage | 77.46% of 52,877 Swift lines in Sources; that is the committed baseline |
| lint | SwiftLint (baseline 295), ruff, `scriptcheck` (85 scripts), `runcheck`, actionlint, `workflow_check.py`: clean |
| openspec | 21 of 21 valid |
| `zizmor .github/workflows` (1.32.0), default and pedantic | no findings |
| with the security layer: `actionlint` (1.7.12), `zizmor --persona pedantic .github` (1.32.0, online with a token and `--offline`), `workflow_check.py` | clean, 8 workflows and `dependabot.yml`; `dependabot.yml` also valid against the SchemaStore schema |
| `bash security/gate.sh --ci --since 1e109504 --skip 20,50,60,70,80,90` | 19 PASS, 7 SKIP, 1 INFO, no FAIL (25 s); `--since HEAD~60 --only 40`: semgrep scanned 67 changed files, 0 new ERROR, 11 new WARNING |
| `bash security/gate.sh --ci --only 20` | PASS once `security/osv-scanner.toml` accepts the five mcp/opentelemetry advisories semgrep pins |
| `make release-gate-selftest` | every planted defect caught in release mode and in `--ci` mode; the missing app is a SKIP in `--ci` |
| `tools/ci/install-security-tools.sh <dir> cppcheck` | Cppcheck 2.22.0 built from the pinned tarball (40 s here); a second run reuses it |
| `fuzz/build-libfuzzer.sh <dir>` | commit `3623fe66` and tree `c7aa7f0f` checked, `libFuzzer.a` built (12 s) |
| `pip install --require-hashes --only-binary :all: -r tools/ci/requirements-security.txt` | semgrep 1.183.0 on Python 3.12 (macOS); `pip download` of the same file for `manylinux_2_34_x86_64` resolves every wheel |

The bundle job's Wine build was not replayed: the October hosted runs built
the bridge, and this replay staged a bridge built earlier on this Mac.

## Run it locally

From the repository root, prefixed with
`~/Library/Caches/cartouche-night/locked.sh` on the maintainer's Mac:

| Job | Command |
|---|---|
| build | `for p in app installer retroarch; do (cd $p && swift build); done; make all overlay-shim fps-counter iconmaker appinfo` (needs `vendor/dobby` and `make dobby`) |
| tests | `sh tools/ci/c-suites.sh; make -s python-tests; (cd installer && swift test --enable-code-coverage); (cd retroarch && swift test --enable-code-coverage)` |
| coverage | `for p in app installer retroarch; do sh tools/ci/export-coverage.sh $p coverage/$p.lcov; done; python3 tools/ci/diff_coverage.py --lcov coverage/*.lcov --base origin/main` |
| lint | `swiftlint lint --strict --baseline tools/ci/swiftlint-baseline.json; ruff check .; make scriptcheck runcheck; actionlint; python3 packaging/tests/workflow_check.py` |
| openspec | `npm ci --prefix tools/ci/openspec && tools/ci/openspec/node_modules/.bin/openspec validate --all --strict --no-interactive` |
| redistribution | `sh packaging/redist-scan.sh . && sh packaging/tests/redist-scan-test.sh` |
| security | `bash security/gate.sh --ci --since origin/main --only 10,30,40,45` (needs gitleaks, actionlint, zizmor, semgrep, jq) |
| c-safety | `C_ASAN_GPU=0 make c-asan; make c-analyze; make fuzz-regress` (needs cppcheck and `brew install mingw-w64`) |
| bundle | the `bundle` job's steps; `make app` needs the Wine trees (`make bridge`) and the fonts; then `make app-payload` and `(cd app && swift test --manifest-cache none --no-parallel --enable-code-coverage)` |

Tools: `brew install swiftlint ruff shellcheck actionlint zizmor gitleaks semgrep
osv-scanner cppcheck`. Audit the workflows with `actionlint` and
`zizmor --persona pedantic .github`.
