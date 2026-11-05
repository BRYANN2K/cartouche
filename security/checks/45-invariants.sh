#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# Text invariants over every tracked source file, parser or not: things that must never appear, and counts that must not grow.
# git grep is used because it is always there; a missing tool must fail, never pass.
set -u
r() { printf '%s\t45-invariants\t%s\t%s\n' "$1" "$2" "$3"; }
cd "$REPO" || exit 1
git grep -P -q 'x' -- Makefile 2>/dev/null || { r FAIL "git grep -P" "unavailable: invariants not checked"; exit 0; }
src=(app/Sources retroarch/Sources installer/Sources dylib fps-counter overlay-shim steam-shim helpers app/Info.plist)
notests=(':!**/Tests/**' ':!vendor/**' ':!dylib/tests/**')
never() { # title, PCRE, [pathspec...]
    local title=$1 re=$2; shift 2
    local specs=("$@"); [ ${#specs[@]} -gt 0 ] || specs=("${src[@]}")
    local hits; hits=$(git grep -n -P -e "$re" -- "${specs[@]}" "${notests[@]}" 2>/dev/null | head -5)
    [ -z "$hits" ] && r PASS "$title" "none" || r FAIL "$title" "$(echo "$hits" | tr '\n' ' ' | cut -c1-400)"
}
never "ATS disabled for all hosts" 'NSAllowsArbitraryLoads' app/Info.plist
never "Keychain readable when locked" 'kSecAttrAccessible(Always|AfterFirstUnlock)\b'
never "get-task-allow entitlement" 'com\.apple\.security\.get-task-allow'
never "a shell started with interpolated text" '"/bin/(ba|z)?sh",\s*\[?\s*"-c",\s*"[^"]*\\\(' 
csrc=(dylib fps-counter overlay-shim steam-shim helpers ntdll-patch framegen/proxy framegen/bridge ':!steam-shim/jsoncpp.cpp' ':!steam-shim/json/**')
never "unsafe C string functions" '(?<![_a-zA-Z])(strcpy|strcat|sprintf|vsprintf|gets)\s*\(' "${csrc[@]}"
never "system()/popen() in C" '(?<![_a-zA-Z.>])(system|popen)\s*\(' "${csrc[@]}"
never "demo hooks outside their files" 'CARTOUCHE_QA_DEMO' "${src[@]}" ':!**/QAEnvironment.swift' ':!**/Demo*.swift'
grow() { # title, PCRE: count now vs at SINCE
    local now before
    now=$(git grep -c -P -e "$2" -- "${src[@]}" "${notests[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
    before=$(git grep -c -P -e "$2" "$SINCE" -- "${src[@]}" "${notests[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
    if [ "$now" -gt "$before" ]; then r WARN "$1" "$before at $SINCE, $now now: review each new one"; else r PASS "$1" "$now (was $before)"; fi
}
grow "permanent deletes (removeItem)" 'removeItem\(at'
grow "plain http URLs" '"http://(?!127\.0\.0\.1|localhost)'
grow "try? on file operations" 'try\? [A-Za-z.]*\.(removeItem|moveItem|copyItem|trashItem)'
grow "@unchecked Sendable" '@unchecked Sendable'
grow "force unwraps of try (try!)" 'try!'
