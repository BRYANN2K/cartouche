#!/bin/sh
# Fails when a folder, zip or tar archive holds a file from Apple's Game Porting
# Toolkit. Its license forbids redistribution, so none may reach the repository
# or a release.
#
#   ./redist-scan.sh <folder, .zip or .tar[.gz|.xz]>...
#
# Matches by file name, and by SHA-256 against redist-hashes.txt (REDIST_HASHES
# overrides it), which catches Apple's files under names Wine also uses.
set -eu

[ $# -gt 0 ] || { echo "usage: redist-scan.sh <folder, .zip or .tar[.gz|.xz]>..." >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd -P)"
hashes="${REDIST_HASHES:-$here/redist-hashes.txt}"
[ -f "$hashes" ] || { echo "redist-scan: $hashes is missing" >&2; exit 2; }

# Basenames, matched without case
NAMES='d3dmetal.framework d3dmetal libd3dshared.dylib libd3dmetal.dylib nvngx-on-metalfx.dll nvngx-on-metalfx.so apple_gptk'
# Name prefixes of the toolkit's own downloads
PREFIXES='game porting toolkit|game_porting_toolkit|evaluation environment for windows games|evaluation_environment_for_windows_games'

found="$(mktemp)"
scratch="$(mktemp -d)"
trap 'rm -rf "$found" "$scratch"' EXIT

# Reads paths on stdin; $1 labels where they come from
flag() {
    while IFS= read -r path; do
        base="$(basename "$path" | tr '[:upper:]' '[:lower:]')"
        hit=
        for n in $NAMES; do
            [ "$base" = "$n" ] && hit=1
        done
        if printf '%s\n' "$base" | grep -Eq "^($PREFIXES)"; then hit=1; fi
        if [ -n "$hit" ]; then echo "$1$path" >> "$found"; fi
    done
}

# Only files of a listed size are hashed, so a whole tree scans quickly
sizes=$(grep -v '^#' "$hashes" | awk 'NF >= 2 && $2 ~ /^[0-9]+$/ { print $2 }' | sort -u)
size_test=
for s in $sizes; do size_test="$size_test -o -size ${s}c"; done
size_test=${size_test# -o }

# $1 folder, $2 label, $3 prefix stripped from reported paths
hash_scan() {
    [ -n "$size_test" ] || return 0
    # shellcheck disable=SC2086
    find "$1" -name .git -prune -o -type f \( $size_test \) -print | while IFS= read -r f; do
        sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
        what=$(awk -v s="$sum" '$1 == s { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }' "$hashes")
        if [ -n "$what" ]; then echo "$2${f#"$3"} (same bytes as $what)" >> "$found"; fi
    done
}

# Prints every leading part of each listed entry, since an archive may name a
# folder only through the files inside it
parts() {
    awk -F/ '{ p = ""; for (i = 1; i <= NF; i++) if ($i != "" && $i != ".") { p = p (p == "" ? "" : "/") $i; print p } }' | sort -u
}

n=0
for target in "$@"; do
    n=$((n + 1))
    case "$target" in
        *.zip) kind=zip ;;
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz) kind=tar ;;
        *) kind=other ;;
    esac
    if [ -d "$target" ]; then
        find "$target" -name .git -prune -o -print | flag ""
        hash_scan "$target" "" ""
    elif [ -f "$target" ] && [ "$kind" != other ]; then
        out="$scratch/$n"
        mkdir -p "$out"
        if [ "$kind" = zip ]; then
            zipinfo -1 "$target" | parts | flag "$target: "
            unzip -qq "$target" -d "$out"
        else
            tar -tf "$target" | parts | flag "$target: "
            tar -xf "$target" -C "$out"
        fi
        hash_scan "$out" "$target: " "$out/"
    else
        echo "redist-scan: $target is neither a folder, a .zip nor a tar archive" >&2
        exit 2
    fi
done

if [ -s "$found" ]; then
    echo "redist-scan: Game Porting Toolkit files found, they must not be redistributed:" >&2
    sort -u "$found" | sed 's/^/    /' >&2
    exit 1
fi
echo "==> redist-scan: no Game Porting Toolkit file in $*"
