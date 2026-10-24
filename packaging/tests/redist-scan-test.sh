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

# Release assets are also tar archives
(cd "$work" && tar -cJf clean.tar.xz clean)
sh "$scan" "$work/clean.tar.xz" >/dev/null || fail "a clean tar.xz was flagged"
rm -rf "$work/dirty"
mkdir -p "$work/dirty/lib/external"
: > "$work/dirty/lib/external/libd3dshared.dylib"
(cd "$work" && tar -czf dirty.tar.gz dirty/lib/external/libd3dshared.dylib)
if sh "$scan" "$work/dirty.tar.gz" > "$work/out" 2>&1; then fail "missed a toolkit name in a tar.gz"; fi
grep -q "dirty.tar.gz: dirty/lib/external/libd3dshared.dylib" "$work/out" || fail "the report does not name the tar entry"

# Apple's bytes under a name Wine also uses are caught by their hash, in a
# folder, a zip and a tar.xz. The planted bytes stand in for Apple's file.
printf 'MZ stand-in for an Apple d3d11.dll\n' > "$work/apple.bin"
sum=$(shasum -a 256 "$work/apple.bin" | cut -d' ' -f1)
size=$(wc -c < "$work/apple.bin" | tr -d ' ')
printf '# test list\n%s %s gptk-test/wine/x86_64-windows/d3d11.dll\n' "$sum" "$size" > "$work/hashes.txt"
REDIST_HASHES="$work/hashes.txt" sh "$scan" "$work/clean" "$work/clean.zip" "$work/clean.tar.xz" >/dev/null \
    || fail "the hash list flagged a clean tree"
rm -rf "$work/renamed" "$work/renamed.zip" "$work/renamed.tar.xz"
mkdir -p "$work/renamed/lib/wine/x86_64-windows"
cp "$work/apple.bin" "$work/renamed/lib/wine/x86_64-windows/d3d11.dll"
(cd "$work" && zip -qrD renamed.zip renamed && tar -cJf renamed.tar.xz renamed)
for target in "$work/renamed" "$work/renamed.zip" "$work/renamed.tar.xz"; do
    if REDIST_HASHES="$work/hashes.txt" sh "$scan" "$target" > "$work/out" 2>&1; then fail "missed Apple's bytes in $target"; fi
    grep -q "d3d11.dll (same bytes as gptk-test/wine/x86_64-windows/d3d11.dll)" "$work/out" \
        || fail "the report does not name the matched file for $target"
done
# The same bytes with one changed are not Apple's
printf 'MZ stand-in for an Apple d3d11.dlx\n' > "$work/renamed/lib/wine/x86_64-windows/d3d11.dll"
REDIST_HASHES="$work/hashes.txt" sh "$scan" "$work/renamed" >/dev/null || fail "other bytes were flagged"

# The shipped list is well formed
bad=$(grep -v '^#' "$here/../redist-hashes.txt" | grep -Ev '^[0-9a-f]{64} [0-9]+ [^ ].*$' || true)
[ -z "$bad" ] || fail "malformed lines in redist-hashes.txt: $bad"
echo "==> redist-scan-test: clean trees pass, planted toolkit files fail by name and by hash"
