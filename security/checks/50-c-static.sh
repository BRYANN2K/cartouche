#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# Static analysis of the shipped C (the dylib injected into Steam, shims, helpers)
set -u
r() { printf '%s\t50-c-static\t%s\t%s\n' "$1" "$2" "$3"; }
cd "$REPO" || exit 1
dirs=(dylib fps-counter overlay-shim steam-shim helpers ntdll-patch)
command -v cppcheck >/dev/null || { r FAIL "cppcheck missing" "brew install cppcheck"; exit 0; }
cppcheck --quiet --enable=warning,portability --inline-suppr --suppress=missingIncludeSystem -I app/Sources/CartoucheIdentity/include \
    -i dylib/tests -i vendor -i steam-shim/jsoncpp.cpp -i steam-shim/json --template='{severity}\t{file}:{line}\t{id}\t{message}' "${dirs[@]}" 2>"$OUT/cppcheck.txt" >/dev/null
errors=$(grep -c '^error' "$OUT/cppcheck.txt"); warnings=$(grep -c '^warning\|^portability' "$OUT/cppcheck.txt")
[ "$errors" = 0 ] && r PASS "cppcheck errors" "none" || r FAIL "cppcheck errors" "$errors: $(grep '^error' "$OUT/cppcheck.txt" | head -3 | cut -f2,3 | tr '\n' ' ')"
[ "$warnings" = 0 ] && r PASS "cppcheck warnings" "none" || r WARN "cppcheck warnings" "$warnings, cppcheck.txt"
if [ "${GATE_MODE:-release}" = ci ]; then
    r SKIP "clang --analyze" "ci mode: the c-safety job runs make c-analyze on macOS"
elif grep -qs '^c-analyze:' Makefile tools/c-safety/c-safety.mk; then
    if make -s c-analyze >"$OUT/c-analyze.log" 2>&1; then r PASS "clang --analyze" "make c-analyze"; else r FAIL "clang --analyze" "c-analyze.log"; fi
else
    r WARN "clang --analyze" "no c-analyze target yet"
fi
