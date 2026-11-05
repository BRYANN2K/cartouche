#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# Nothing from Apple's Game Porting Toolkit, D3DMetal, NVIDIA or Intel ships (license)
set -u
r() { printf '%s\t70-redistribution\t%s\t%s\n' "$1" "$2" "$3"; }
for target in "$REPO" "$APP"; do
    [ -e "$target" ] || continue
    if sh "$REPO/packaging/redist-scan.sh" "$target" >"$OUT/redist-$(basename "$target").log" 2>&1; then r PASS "redist-scan $(basename "$target")" "clean"; else r FAIL "redist-scan $(basename "$target")" "redist-$(basename "$target").log"; fi
done
if [ "${GATE_MODE:-release}" = ci ] && [ ! -d "$APP" ]; then r SKIP "NVIDIA/Intel binaries in the app" "ci mode: no app"; exit 0; fi
hits=$(find "$APP" -iname 'nvngx*' -o -iname '*nvapi*' -o -iname 'libxess*' -o -iname 'igxess*' 2>/dev/null | head -3)
[ -z "$hits" ] && r PASS "NVIDIA/Intel binaries in the app" "none" || r FAIL "NVIDIA/Intel binaries in the app" "$hits"
