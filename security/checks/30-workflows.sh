#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# GitHub workflows: syntax, injection, permissions, pinning, self-hosted runners on pull requests
set -u
r() { printf '%s\t30-workflows\t%s\t%s\n' "$1" "$2" "$3"; }
wf="$REPO/.github/workflows"
[ -d "$wf" ] || { r PASS "workflows" "none"; exit 0; }
command -v actionlint >/dev/null && command -v zizmor >/dev/null || { r FAIL "workflow tools" "actionlint or zizmor missing"; exit 0; }
if actionlint -no-color "$wf"/*.y*ml >"$OUT/actionlint.log" 2>&1; then r PASS "actionlint" "clean"; else r FAIL "actionlint" "$(grep -c . "$OUT/actionlint.log") line(s), actionlint.log"; fi
zizmor --offline --format json --min-severity medium "$wf" > "$OUT/zizmor.json" 2>"$OUT/zizmor.log"
n=$(jq length "$OUT/zizmor.json" 2>/dev/null || echo "?")
if [ "$n" = 0 ]; then r PASS "zizmor" "no medium+ finding"; else r FAIL "zizmor" "$n finding(s), zizmor.json"; fi
selfhosted=$(for f in "$wf"/*.y*ml; do grep -q 'pull_request' "$f" && grep -qE 'runs-on:.*self-hosted|MACOS_RUNNER' "$f" && basename "$f"; done | tr '\n' ' ')
[ -z "$selfhosted" ] && r PASS "self-hosted on pull_request" "none" || r FAIL "self-hosted on pull_request" "$selfhosted"
secrets=$(grep -nE 'SPARKLE_PRIVATE_KEY|CODESIGN_IDENTITY|\.p12|CERTIFICATE' "$wf"/*.y*ml 2>/dev/null | head -5 | tr '\n' ' ')
[ -z "$secrets" ] && r PASS "signing material in workflows" "none" || r FAIL "signing material in workflows" "$secrets"
