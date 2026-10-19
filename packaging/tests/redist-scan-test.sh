#!/bin/sh
# The redistribution scan passes a clean tree and zip, and fails on planted
# Game Porting Toolkit names, in a folder and inside a zip.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
scan="$here/../redist-scan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "redist-scan-test: $*" >&2; exit 1; }

mkdir -p "$work/clean/lib/wine/x86_64-windows"
: > "$work/clean/lib/wine/x86_64-windows/d3d11.dll"
: > "$work/clean/README-d3dmetal.txt"
sh "$scan" "$work/clean" >/dev/null || fail "a clean tree was flagged"
(cd "$work" && zip -qr clean.zip clean)
sh "$scan" "$work/clean.zip" >/dev/null || fail "a clean zip was flagged"

for planted in "lib/external/D3DMetal.framework/Versions/A/D3DMetal" "lib/external/libd3dshared.dylib" \
    "Game Porting Toolkit 3.0.dmg"; do
    rm -rf "$work/dirty" "$work/dirty.zip"
    mkdir -p "$work/dirty/$(dirname "$planted")"
    : > "$work/dirty/$planted"
    if sh "$scan" "$work/clean" "$work/dirty" > "$work/out" 2>&1; then fail "missed $planted in a folder"; fi
    grep -q "$(basename "$planted")" "$work/out" || fail "the report does not name $planted"
    # zip -D leaves folder entries out, as release zips may
    (cd "$work" && zip -qrD dirty.zip dirty)
    if sh "$scan" "$work/dirty.zip" > "$work/out" 2>&1; then fail "missed $planted in a zip"; fi
    grep -q "dirty.zip: " "$work/out" || fail "the report does not name the zip for $planted"
done

if sh "$scan" "$work/clean/README-d3dmetal.txt" >/dev/null 2>&1; then fail "a plain file was accepted as a target"; fi
echo "==> redist-scan-test: clean trees pass, planted toolkit files fail"
