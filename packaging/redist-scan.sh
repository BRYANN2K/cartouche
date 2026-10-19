#!/bin/sh
# Fails when a folder or zip holds a file from Apple's Game Porting Toolkit.
# Its license forbids redistribution, so none may reach the repository or a release.
#
#   ./redist-scan.sh <folder or .zip>...
#
# Matches by file name. Names Wine also uses (d3d11.dll and so on) cannot be told
# apart this way; P2 adds a hash list for those.
set -eu

[ $# -gt 0 ] || { echo "usage: redist-scan.sh <folder or .zip>..." >&2; exit 2; }

# Basenames, matched without case
NAMES='d3dmetal.framework d3dmetal libd3dshared.dylib libd3dmetal.dylib'
# Name prefixes of the toolkit's own downloads
PREFIXES='game porting toolkit|game_porting_toolkit|evaluation environment for windows games'

found="$(mktemp)"
trap 'rm -f "$found"' EXIT

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

for target in "$@"; do
    if [ -d "$target" ]; then
        find "$target" -name .git -prune -o -print | flag ""
    elif [ -f "$target" ] && [ "${target%.zip}" != "$target" ]; then
        # A zip may list a folder only through the files inside it, so check
        # every leading part of each entry
        zipinfo -1 "$target" \
            | awk -F/ '{ p = ""; for (i = 1; i <= NF; i++) if ($i != "") { p = p (p == "" ? "" : "/") $i; print p } }' \
            | sort -u | flag "$target: "
    else
        echo "redist-scan: $target is neither a folder nor a .zip" >&2
        exit 2
    fi
done

if [ -s "$found" ]; then
    echo "redist-scan: Game Porting Toolkit files found, they must not be redistributed:" >&2
    sort -u "$found" | sed 's/^/    /' >&2
    exit 1
fi
echo "==> redist-scan: no Game Porting Toolkit file in $*"
