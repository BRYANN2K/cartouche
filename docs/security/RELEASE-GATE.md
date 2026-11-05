# Release gate

Run before every release, on the Mac that builds and signs it:

```sh
cp docs/security/releases/TEMPLATE.md docs/security/releases/<version>.md   # fill it during the review
make release-gate          # builds the app, runs every check, writes security/out/<version>-<sha>/report.md
make release-gate-selftest # proves the gate still catches planted defects; run after editing security/
```

The CI runs the same checks on every pull request and push, without an app:

```sh
bash security/gate.sh --ci --since <base> --only 10,30,40,45   # the ci.yml security job
bash security/gate.sh --ci --only 20                           # the nightly osv-scanner job
```

`--ci` (or `GATE_MODE=ci`) checks an app only when `--app` names one, reports the
built-app parts of 10, 20 and 70 and the clang part of 50 as `SKIP`, and skips 60, 80 and
90, which need the signed app, the Swift tests and the release review. `--only` runs the
listed checks; `--since` must be a commit in the clone. Without `--ci` nothing changed.

A release ships only when the gate exits 0. Copy the generated `report.md` into `docs/security/releases/<version>.md` under the review.

| Check | What fails it |
|---|---|
| 10-secrets | gitleaks finds a secret in the commits since the last tag, or in the built app |
| 20-dependencies | osv-scanner finds a vulnerability with CVSS ≥ 7 (or unknown) in the lockfiles or in the app SBOM (syft) |
| 30-workflows | actionlint or zizmor (medium+), a self-hosted runner on pull_request, signing material in a workflow |
| 40-code-rules | a new ERROR from `security/rules` (semgrep, Swift and C) since the last tag; new WARNINGs are listed |
| 45-invariants | git grep over every source: ATS off, weak Keychain accessibility, get-task-allow, shell with interpolation, unsafe C string functions, system/popen, demo hooks outside their files; warns when deletes, http URLs, `try?` on file operations or `@unchecked Sendable` grow |
| 50-c-static | a cppcheck error in shipped C; clang --analyze through `make c-analyze` |
| 60-artifact | codesign strict fails, get-task-allow, load paths outside the system and the bundle, rpaths in user-writable folders, writable or setuid files, ATS off, update feed not https, no Sparkle key; warns without hardened runtime (fails with `REQUIRE_RUNTIME=1`, audit M-2) |
| 70-redistribution | redist-scan finds Game Porting Toolkit or D3DMetal files; NVIDIA or Intel binaries in the app |
| 80-security-tests | a failure in the suites that guard agent levels, approvals, MCP, pinned downloads, manifests, archives, uninstall and secrets |
| 90-review | the release review is missing, has an unchecked item, or lacks the AI review or the sign-off |

Accepting a finding happens in the tool's own file, reviewed in a diff: `.gitleaksignore` (fingerprint + reason) or an `[[allowlists]]` entry in `security/gitleaks.toml` scoped to one path and value, `security/osv-scanner.toml` (`[[IgnoredVulns]]` with `ignoreUntil` and `reason`), `// nosemgrep: <rule>` with the reason on the same line.
