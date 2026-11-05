#!/bin/bash
# shellcheck disable=SC2015 # "test && r PASS || r FAIL": r is a printf, it never fails
# The app that ships: signature, entitlements, hardened runtime, load paths, permissions, ATS, update feed
set -u
r() { printf '%s\t60-artifact\t%s\t%s\n' "$1" "$2" "$3"; }
[ -d "$APP" ] || { r FAIL "app" "no app at $APP"; exit 0; }
REQUIRE_RUNTIME=${REQUIRE_RUNTIME:-1}
if codesign --verify --deep --strict "$APP" >"$OUT/codesign.log" 2>&1; then r PASS "codesign --verify --deep --strict" "valid"; else r FAIL "codesign --verify --deep --strict" "codesign.log"; fi
machos=$(find "$APP" -type f -perm -u+x -o -type f -name '*.dylib' -o -type f -name '*.so' | while read -r f; do file -b "$f" | grep -q Mach-O && echo "$f"; done)
echo "$machos" > "$OUT/machos.txt"
bad_ent=""; no_rt=""
while read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$APP/"}
    ent=$(codesign -d --entitlements :- "$f" 2>/dev/null)
    echo "$ent" | grep -q 'get-task-allow' && bad_ent="$bad_ent $rel(get-task-allow)"
    for e in $(echo "$ent" | grep -oE 'com\.apple\.security\.cs\.[a-z.-]+'); do echo "$rel: $e" >> "$OUT/exception-entitlements.txt"; done
    # The runtime flag matters for programs; a dylib follows the process that loads it
    file -b "$f" | grep -q executable && { codesign -dv "$f" 2>&1 | grep -q 'flags=.*runtime' || no_rt="$no_rt $rel"; }
    self=$(otool -D "$f" 2>/dev/null | grep -v ':$' | head -1)
    [ -n "$self" ] && case "$self" in @*) ;; *) echo "$rel id $self" >> "$OUT/absolute-ids.txt" ;; esac
    otool -L "$f" 2>/dev/null | grep -v ':$' | awk '{print $1}' | grep -vxF "${self:-//none//}" | grep -vE '^(/System/|/usr/lib/|@rpath/|@loader_path/|@executable_path/)' | sed "s|^|$rel -> |" >> "$OUT/absolute-loads.txt"
    otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{getline;getline;print $2}' | grep -vE '^(@(loader|executable)_path|/usr/lib/swift$)' | sed "s|^|$rel rpath |" >> "$OUT/rpaths.txt"
done <<< "$machos"
[ -z "$bad_ent" ] && r PASS "get-task-allow" "absent" || r FAIL "get-task-allow" "$bad_ent"
# Every helper is a real binary: an empty libarchive.dylib once shipped in local builds and broke archive extraction
broken=""
for h in "$APP/Contents/Helpers/"*; do
    [ -e "$h" ] || continue
    file -b "$h" | grep -q 'Mach-O' || broken="$broken ${h##*/}($(wc -c < "$h" | tr -d ' ') bytes)"
done
for need in cartouche-mcp innoextract libarchive.dylib; do [ -e "$APP/Contents/Helpers/$need" ] || broken="$broken $need(missing)"; done
[ -z "$broken" ] && r PASS "helpers are real binaries" "cartouche-mcp, innoextract, libarchive.dylib" || r FAIL "helpers are real binaries" "$broken"
[ -s "$OUT/absolute-loads.txt" ] && r FAIL "load paths outside the system and the bundle" "$(head -3 "$OUT/absolute-loads.txt" | tr '\n' ' ')" || r PASS "load paths" "system or bundle-relative only"
# An rpath a user can write to lets anyone plant a dylib; a root-owned one only leaks a build path
userw=$(grep -E ' rpath (/Users/|/tmp/|/private/tmp/|/opt/homebrew/|/usr/local/)' "$OUT/rpaths.txt" 2>/dev/null | head -3 | tr '\n' ' ')
[ -n "$userw" ] && r FAIL "LC_RPATH in user-writable folders (dylib hijack)" "$userw" \
  || { [ -s "$OUT/rpaths.txt" ] && r WARN "absolute LC_RPATH (build paths)" "$(head -2 "$OUT/rpaths.txt" | tr '\n' ' ')" || r PASS "LC_RPATH" "bundle-relative or system Swift only"; }
[ -s "$OUT/absolute-ids.txt" ] && r WARN "absolute dylib install names (leak build paths)" "$(head -2 "$OUT/absolute-ids.txt" | tr '\n' ' ')" || r PASS "dylib install names" "relative"
allowed="$REPO/security/allow/exception-entitlements.txt"
extra=$(grep -vxF -f <(grep -v '^#' "$allowed" 2>/dev/null) "$OUT/exception-entitlements.txt" 2>/dev/null | head -3 | tr '\n' ' ')
[ -z "$extra" ] && r PASS "exception entitlements" "only the reviewed ones (security/allow/exception-entitlements.txt)" || r FAIL "exception entitlements not reviewed" "$extra"
n=$(echo "$no_rt" | wc -w | tr -d ' ')
if [ "$n" = 0 ]; then r PASS "hardened runtime" "every Mach-O"; elif [ "$REQUIRE_RUNTIME" = 1 ]; then r FAIL "hardened runtime" "$n binaries without it (audit M-2)"; else r WARN "hardened runtime" "$n binaries without it (REQUIRE_RUNTIME=0)"; fi
ww=$(find "$APP" \( -perm -o+w -o -perm -g+w \) ! -type l | head -3)
[ -z "$ww" ] && r PASS "group/world-writable files" "none" || r FAIL "group/world-writable files" "$ww"
su=$(find "$APP" -perm -4000 -o -perm -2000 | head -3)
[ -z "$su" ] && r PASS "setuid/setgid" "none" || r FAIL "setuid/setgid" "$su"
plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" "$plist" 2>/dev/null | grep -q true && r FAIL "ATS" "NSAllowsArbitraryLoads" || r PASS "ATS" "no global exception"
ex=$(/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSExceptionDomains" "$plist" 2>/dev/null | grep -E '^\s{4}[a-z0-9.-]+ = Dict' | awk '{print $1}' | tr '\n' ' ')
[ -z "$ex" ] && r PASS "ATS exception domains" "none" || r WARN "ATS exception domains" "$ex (each needs a reason in SECURITY.md)"
feed=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$plist" 2>/dev/null); key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$plist" 2>/dev/null)
case "$feed" in https://*) r PASS "update feed" "$feed" ;; *) r FAIL "update feed" "not https: $feed" ;; esac
[ -n "$key" ] && r PASS "Sparkle public key" "present" || r FAIL "Sparkle public key" "missing"
xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine && r WARN "quarantine" "set on the built app" || r PASS "quarantine" "not set"
