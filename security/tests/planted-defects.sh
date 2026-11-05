#!/bin/bash
# shellcheck disable=SC2015,SC2016 # "grep && echo || fail=1" never fails in the echo; the planted workflow keeps ${{ }} literal
# The gate must catch every planted defect: run it on a throwaway clone where each one is committed.
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
repo=$(cd "$here/.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git clone -q --no-hardlinks "$repo" "$work/r"
cd "$work/r" || exit 1; git config user.email t@t; git config user.name t
rm -rf security && cp -R "$here" security && rm -rf security/out && git add -A && git commit -qm "gate under test" --allow-empty
base=$(git rev-parse HEAD)
# Each defect: file, content, the result line the gate must report
printf '#include <string.h>\nvoid f(char *d, const char *s) { strcpy(d, s); }\n' > dylib/planted.c
printf 'import Foundation\nlet q: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAlways]\n' > app/Sources/NotProtonApp/Planted.swift
printf 'name: planted\non: pull_request\njobs:\n  a:\n    runs-on: [self-hosted]\n    steps:\n      - run: echo "${{ secrets.SPARKLE_PRIVATE_KEY }}"\n' > .github/workflows/planted.yml
# The fake key is split so it never sits whole in the repo
printf 'aws_access_key_id = %s\naws_secret_access_key = %s\n' "AKIA""Z7QW3RTYX4LMNOPQ" "9fJq2Lw8Xz4K""p1Vb7Nc3Md6Rt0Ys5Ue2Hg8Ia4Ob" > planted.env
git add -A; git commit -qm planted
bash security/gate.sh --since "$base" --app /nonexistent --skip 20,50,60,70,80,90 > "$work/gate.log" 2>&1
out=$(cat security/out/*/results.tsv 2>/dev/null)
[ -n "$out" ] || { echo "gate produced no results:"; cat "$work/gate.log"; exit 1; }
fail=0
expect() { echo "$out" | grep -E "^FAIL	$1	$2" >/dev/null && echo "caught: $1 $2" || { echo "MISSED: $1 $2"; fail=1; }; }
expect 10-secrets "commits since"
expect 30-workflows "self-hosted on pull_request"
expect 30-workflows "signing material in workflows"
expect 45-invariants "Keychain readable when locked"
expect 45-invariants "unsafe C string functions"
expect 40-code-rules "new ERROR findings"
# ci mode: the same defects fail, the missing app is a SKIP, never a FAIL
rm -rf security/out
bash security/gate.sh --ci --since "$base" --only 10,30,40,45 > "$work/gate-ci.log" 2>&1
out=$(cat security/out/*/results.tsv 2>/dev/null)
[ -n "$out" ] || { echo "ci gate produced no results:"; cat "$work/gate-ci.log"; exit 1; }
expect 10-secrets "commits since"
expect 30-workflows "self-hosted on pull_request"
expect 45-invariants "unsafe C string functions"
expect 40-code-rules "new ERROR findings"
echo "$out" | grep -qE '^SKIP	10-secrets	built app' && echo "ci mode: built app skipped" || { echo "MISSED: ci mode did not skip the app"; fail=1; }
echo "$out" | grep -E '^FAIL' | grep -qi 'no app' && { echo "WRONG: ci mode failed on the missing app"; fail=1; }
exit $fail
