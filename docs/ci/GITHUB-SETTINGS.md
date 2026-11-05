# GitHub settings to approve

The repository settings the CI security layer relies on, for `BRYANN2K/cartouche`. None
is applied: each waits for the maintainer's approval, then runs as written, in this order.
Every command uses `gh api` (`gh` defaults to the upstream fork, so the path names the repo).

State read on 2026-11-05 with `GET` calls only:

| Setting | Now |
|---|---|
| Actions | disabled; `sha_pinning_required: false` |
| Default `GITHUB_TOKEN` permissions | `read`, cannot approve pull requests |
| Fork pull request approval | `first_time_contributors` |
| Rulesets, branch protection on `main` | none |
| Dependabot alerts / security updates | off / off |
| Code scanning default setup | `not-configured` |
| Secret scanning / push protection | off / off |
| Private vulnerability reporting | on |

```sh
R=repos/BRYANN2K/cartouche
```

## 1. Enable Actions, GitHub-owned actions and Scorecard only, pinned by SHA

Every workflow uses `actions/*`, `github/codeql-action/*` and `ossf/scorecard-action`, all
pinned by full commit SHA. `sha_pinning_required` makes GitHub refuse a tag or branch ref.

```sh
gh api -X PUT $R/actions/permissions --input - <<'EOF'
{"enabled": true, "allowed_actions": "selected", "sha_pinning_required": true}
EOF
gh api -X PUT $R/actions/permissions/selected-actions --input - <<'EOF'
{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": ["ossf/scorecard-action@*"]}
EOF
```

Keep as they are (already right): token permissions `read` and no PR approval by
workflows; first-time contributors need approval before their workflows run. To ask for
approval from every outside contributor instead:

```sh
gh api -X PUT $R/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
```

No runner is registered and none should be: every job runs on GitHub-hosted runners.

## 2. Branch ruleset for `main` and `release/**`: required checks, no force push

Two rulesets, so the admin bypass of the review (one maintainer cannot approve their own
pull request) never bypasses a check. The check names are the job names of `ci.yml`
(docs/ci/CI.md); `15368` is the GitHub Actions app, so only Actions can report them.
`codeql *` is left out until its first green run (docs/ci/CI.md).

```sh
gh api -X POST $R/rulesets --input - <<'EOF'
{
  "name": "main and release: checks, history",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH", "refs/heads/release/**"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "do_not_enforce_on_create": false,
      "required_status_checks": [
        {"context": "required", "integration_id": 15368},
        {"context": "build", "integration_id": 15368},
        {"context": "tests", "integration_id": 15368},
        {"context": "coverage", "integration_id": 15368},
        {"context": "lint", "integration_id": 15368},
        {"context": "openspec validate", "integration_id": 15368},
        {"context": "redistribution scan", "integration_id": 15368},
        {"context": "bundle", "integration_id": 15368},
        {"context": "security", "integration_id": 15368},
        {"context": "c-safety", "integration_id": 15368}
      ]}}
  ]
}
EOF

gh api -X POST $R/rulesets --input - <<'EOF'
{
  "name": "main and release: one review",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH", "refs/heads/release/**"], "exclude": []}},
  "rules": [
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["merge", "squash", "rebase"]}}
  ]
}
EOF
```

`bypass_mode: pull_request` lets the admin merge their own pull request without a review,
through the pull request only: never a direct push, and the checks still apply.
To cover `dev` and `beta` too (docs/ci/CI.md lists them), add `"refs/heads/dev"` and
`"refs/heads/beta"` to both `include` lists.

Optional, not recommended yet: linear history. The branches are merged with merge commits
today, so this rule would block those merges.

```sh
gh api -X POST $R/rulesets --input - <<'EOF'
{"name": "main: linear history", "target": "branch", "enforcement": "active", "bypass_actors": [],
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "rules": [{"type": "required_linear_history"}]}
EOF
```

## 3. Tag rulesets for `v*`: only maintainers, signed

Again two rulesets, so the maintainers who may create release tags never bypass the
signature rule. Role ids: 2 maintain, 5 admin.

```sh
gh api -X POST $R/rulesets --input - <<'EOF'
{
  "name": "release tags: maintainers only",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"},
    {"actor_id": 2, "actor_type": "RepositoryRole", "bypass_mode": "always"}
  ],
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]
}
EOF

gh api -X POST $R/rulesets --input - <<'EOF'
{
  "name": "release tags: signed",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "required_signatures"}]
}
EOF
```

Unverified until the first signed tag is pushed: whether GitHub's `required_signatures`
judges the tag object or the commit it points to. Sign both (`git tag -s`, signed commits)
so either reading passes; the maintainer's signing key must be added to the GitHub account
as a signing key.

## 4. Dependabot alerts and security updates

`.github/dependabot.yml` groups the security pull requests; these switch them on.

```sh
gh api -X PUT $R/vulnerability-alerts
gh api -X PUT $R/automated-security-fixes
```

## 5. Code scanning: default setup stays off

`codeql.yml` is the advanced setup; GitHub refuses SARIF uploads from a workflow while
the default setup is on. It is `not-configured` now. If it ever gets switched on:

```sh
gh api -X PATCH $R/code-scanning/default-setup -f state=not-configured
```

## 6. Secret scanning and push protection

Free on a public repository. Push protection refuses a push that contains a known secret
format; `security/gitleaks.toml` and the `security` job cover the rest.

```sh
gh api -X PATCH $R --input - <<'EOF'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"}}}
EOF
```

## 7. Private vulnerability reporting

Already on (`GET $R/private-vulnerability-reporting` gives `{"enabled":true}`). Nothing to do;
to switch it on again if it is ever turned off:

```sh
gh api -X PUT $R/private-vulnerability-reporting
```

## Check afterwards

```sh
gh api $R/actions/permissions
gh api $R/rulesets --jq '.[] | .name + " " + .enforcement'
gh api $R --jq .security_and_analysis
gh api $R/automated-security-fixes
gh api $R/vulnerability-alerts -i | head -1    # 204 when on
```

The first pull request after section 2 shows whether every required name matches a check
GitHub reports: a check that never reports leaves the merge box waiting on it.
