# Cartouche CI and release gate

Goal: no regression, no known vulnerability and no quality drop reaches `main` or a release. Two layers:
- **CI** (GitHub Actions, every pull request and push): fast, hermetic, blocking.
- **Release gate** (`make release-gate` on the maintainer's Mac, before every release): the CI checks again on the exact artifact that ships, plus the checks that need the signed app, the payload or licensed files that never go to hosted runners.

Rules kept from the project: no signing material, GPTK, D3DMetal, NVIDIA or Intel binaries on hosted runners; releases are built and signed on the Mac; nothing is pushed without the maintainer.

## What runs where

| # | Check | Tools | PR | Nightly | Release gate | Blocks | Status (2026-11-05) |
|---|---|---|---|---|---|---|---|
| 1 | Build, warnings as errors on touched targets | swift build, make | yes | | yes | yes | wired: `build`, `bundle` (ci.yml) |
| 2 | Unit and integration tests | Swift Testing, InstallerKit, RetroArchKit, python unittest, C hermetic suites | yes | | yes | yes | wired: `tests`, `bundle`; the first run is red on the known failures in CI.md |
| 3 | Regression: snapshot tests of key screens, golden files for manifests, launch scripts and Steam tool lists | Swift Testing + PNG diff, golden files | yes | | yes | yes | partial: regression tests run inside `tests` and `bundle` (docs/ci/REGRESSIONS.md); snapshot PNG diff in the app tests; no separate job |
| 4 | Coverage, no drop on changed files | llvm-cov, diff coverage | yes | | | yes | wired: `coverage` |
| 5 | Lint and format | SwiftLint (custom security rules), swift-format, ruff, shellcheck | yes | | | yes | wired: `lint` (swift-format not adopted) |
| 6 | Static analysis, Swift | CodeQL (pinned macOS/Xcode 26: Xcode 27 is unsupported), semgrep project rules, invariant tests (ripgrep: every Swift file, since semgrep parses only 57%) | yes | | yes | yes on new findings | semgrep + invariants wired in `security`; CodeQL in `codeql.yml`, not required until its first green hosted run |
| 7 | Static analysis, C (Steam dylib, shims, helpers) | clang --analyze, cppcheck, semgrep C rules | yes | | yes | yes | wired: `c-safety` (`make c-analyze`: clang --analyze, cppcheck 2.22.0); semgrep C rules in `security` |
| 8 | Memory safety, C | ASan + UBSan builds of the C hermetic suites | yes | | yes | yes | wired: `c-safety` (`make c-asan`); GPU suites skipped on hosted runners |
| 9 | Fuzzing of parsers (VDF, JSON, manifests, archives, installer metadata) | libFuzzer (C), swift-fuzz harnesses | | yes, 30 min | 10 min smoke | crash = blocks | wired: `nightly.yml` `fuzz <harness>`, 30 min each by default; seeds and past crashes replayed on every PR (`c-safety`); no swift-fuzz harness yet |
| 10 | Secrets | gitleaks (git diff and history), gitleaks on the built app | yes | | yes | yes | wired: `security` (gitleaks on the run's commits); GitHub secret scanning and push protection await the settings in GITHUB-SETTINGS.md |
| 11 | Dependencies | osv-scanner (Package.resolved, python, vendored list, SBOM), Dependabot | yes | yes | yes | High/Critical | `nightly.yml` `osv-scanner` and `.github/dependabot.yml`; not on PR, so a new advisory never blocks an unrelated PR |
| 12 | Workflows | zizmor, actionlint, pinned actions, least privilege, no self-hosted runner on pull_request | yes | | yes | yes | wired: `security` (actionlint, zizmor, self-hosted, signing material), `lint` (actionlint) |
| 13 | Supply chain | OpenSSF Scorecard, SBOM (syft), build provenance attestation for Cartouche Wine | | weekly | yes | Scorecard < 7 warns | Scorecard in `scorecard.yml` (weekly, push to main); SBOM in the release gate; provenance not started |
| 14 | Artifact checks | codesign strict, entitlements allowlist, hardened runtime, rpath and absolute load paths, permissions, ATS, Sparkle feed key, redist-scan (no GPTK/D3DMetal/NVIDIA) | | | yes | yes | release gate only (60-artifact) |
| 15 | Security review of the release diff | checklist + Claude Code security review of `git diff <last tag>..HEAD` on sensitive paths, signed off in the release report | | | yes | yes | release gate only (90-review) |
| 16 | Mutation testing on security-critical modules (agent access levels, path containment, manifest verification) | Muter | | weekly | | warns | not started |

"Wired" means the job exists on `BRYANN2K/ci-integration` and passed every local replay that could run off GitHub; `security`, `c-safety`, `codeql.yml`, `scorecard.yml` and `nightly.yml` have not had a hosted run yet.

## Gates
- Pull requests: checks 1 to 8, 10 and 12 must pass (check names in docs/ci/CI.md); branch protection requires them, one review, no force push, signed tags only for `v*` (docs/ci/GITHUB-SETTINGS.md). Dependencies (11) run nightly and through Dependabot instead.
- Release: every row marked "Release gate" passes on the shipped artifact; the report `docs/security/releases/<version>.md` lists every check, the tool versions, and the reviewer sign-off. Accepted findings live in the tools' own suppression files (`.gitleaksignore`, `osv-scanner.toml` with `ignoreUntil` and reason, `// nosemgrep: <rule>` with a reason) so each acceptance is reviewed in a diff.

## Known limits
- CodeQL cannot trace Swift with Xcode 27 or analyse Swift 6.4 (GitHub changelog 2026-10-19): the CodeQL job is pinned to macOS 26 / Xcode 26 and must fail loudly if 0 % of files are extracted.
- Semgrep OSS parses 386 of 682 Swift files: it is a complement, not the only Swift scanner.
- Fuzzing on macOS: ASan with libFuzzer works with `-rss_limit_mb=0`; some dylib/dlopen paths need `-mllvm -asan-globals=0`.
