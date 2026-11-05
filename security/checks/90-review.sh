#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# A human-signed security review of the release diff, with the AI review attached
set -u
r() { printf '%s\t90-review\t%s\t%s\n' "$1" "$2" "$3"; }
cd "$REPO" || exit 1
sensitive='^(app/Sources/NotProtonApp/(Agent|MCP|Stores|Installer|Runners|Support|Model)/|dylib/|steam-shim/|overlay-shim/|fps-counter/|helpers/|installer/|retroarch/Sources/RetroArchKit/(MCP|Play)|packaging/|\.github/|Makefile|app/Info.plist|SECURITY.md)'
git diff --name-only "$SINCE"..HEAD | grep -E "$sensitive" > "$OUT/sensitive-changes.txt"
n=$(wc -l < "$OUT/sensitive-changes.txt" | tr -d ' ')
r INFO "sensitive files changed since $SINCE" "$n, sensitive-changes.txt"
report="$REPO/docs/security/releases/$VERSION.md"
if [ ! -f "$report" ]; then r FAIL "release review" "missing $report (copy docs/security/releases/TEMPLATE.md)"; exit 0; fi
grep -qE '^- \[ \]' "$report" && r FAIL "release review checklist" "unchecked items in $report" || r PASS "release review checklist" "all items checked"
grep -qE '^Sign-off: .+' "$report" && r PASS "release review sign-off" "$(grep -E '^Sign-off:' "$report" | head -1)" || r FAIL "release review sign-off" "no 'Sign-off:' line in $report"
grep -qE '^AI review: .+' "$report" && r PASS "AI security review" "attached" || r FAIL "AI security review" "no 'AI review:' line in $report"
