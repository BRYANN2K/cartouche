#!/bin/sh
# Proves that two different builds signed with the same identity share one
# keychain ACL: build A writes a dedicated item in the login keychain, build B
# reads it. A third build signed with another identity must NOT get in without
# a prompt. A prompt blocks the call, so every run is bounded: a hang means a
# prompt appeared.
#
#   ./keychain-identity-test.sh <identity> [<keychain>]
#
# The item (service dev.bryann2k.cartouche.k2proof, account builds) is deleted
# at the end. If a leftover from an earlier identity remains, remove it in
# Keychain Access first; no real secret is ever touched.
set -eu

identity=${1:?usage: keychain-identity-test.sh <identity> [<keychain>]}
kc=${2:-}
here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "keychain-identity-test: $*" >&2; exit 1; }

# A keychain prompt blocks on a dialog, so bound every call: 124 means a prompt
run_bounded() {
    "$@" & pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 30 ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; return 124; fi
        sleep 1
    done
    wait "$pid"
}

sign() {
    if [ -n "$kc" ]; then
        run_bounded codesign -f -s "$identity" --keychain "$kc" --identifier dev.bryann2k.cartouche.k2proof "$1"
    else
        run_bounded codesign -f -s "$identity" --identifier dev.bryann2k.cartouche.k2proof "$1"
    fi
}

for tag in a b c; do
    clang -O -framework Security -framework CoreFoundation -DKC_TAG="\"$tag\"" \
        -o "$work/probe-$tag" "$here/kc-identity-probe.c"
done
sign "$work/probe-a"
sign "$work/probe-b"
codesign -f -s - --identifier dev.bryann2k.cartouche.k2proof "$work/probe-c"
[ "$("$work/probe-a" tag)" != "$("$work/probe-b" tag)" ] || fail "the two builds are identical, the test proves nothing"
cmp -s "$work/probe-a" "$work/probe-b" && fail "the two builds are identical, the test proves nothing"

# A stale item signed by another identity cannot be deleted silently; remove it
# in Keychain Access (service dev.bryann2k.cartouche.k2proof) and run again.
if ! run_bounded "$work/probe-a" delete; then
    fail "could not delete a previous k2proof item without a prompt; remove it in Keychain Access and run again"
fi

value="k2-$$-$(date +%s)"
got_a="$(run_bounded "$work/probe-a" write "$value")" || fail "build A could not write the item without a prompt (rc=$?)"
[ "$got_a" = "$value" ] || fail "build A wrote '$got_a', expected '$value'"

got_b="$(run_bounded "$work/probe-b" read)" || fail "build B was asked for keychain access (rc=$?) — the ACL does not span builds"
[ "$got_b" = "$value" ] || fail "build B read '$got_b', expected '$value'"

# Red case: a different signature must not read the item silently.
rc=0
run_bounded "$work/probe-c" read > /dev/null || rc=$?
if [ "$rc" = 0 ]; then
    "$work/probe-a" delete || true
    fail "a build signed ad-hoc read the item without a prompt — the ACL does not discriminate"
fi
[ "$rc" = 124 ] && echo "==> ad-hoc build: access attempt prompted (as expected), caller killed" || echo "==> ad-hoc build: refused (rc=$rc, as expected)"

run_bounded "$work/probe-a" delete || fail "cleanup delete failed"
echo "==> keychain-identity-test: build B read build A's item without a prompt"
