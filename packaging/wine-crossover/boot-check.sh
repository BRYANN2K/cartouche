#!/bin/sh
# Starts winecfg in a fresh prefix and times how long its window takes to show,
# counting the prefix creation. Saves a screenshot and the time.
#
#   ./boot-check.sh <runner root> <out folder> [limit seconds, default 60]
#
# Writes <out>/winecfg.png and <out>/boot.txt. Exits 1 past the limit. Needs a
# logged-in GUI session (GitHub's macOS runners have one).
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
[ $# -ge 2 ] || { echo "usage: boot-check.sh <runner root> <out folder> [limit]" >&2; exit 2; }
root=$1 out=$2 limit=${3:-60}
mkdir -p "$out"

work=$(mktemp -d)
export HOME="$work/home" WINEPREFIX="$work/prefix" WINEDEBUG=-all
mkdir -p "$HOME"
cleanup() {
    "$root/bin/wineserver" -k 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# Compiled first, so the compile time is not counted
swiftc -O "$here/wait-window.swift" -o "$work/wait-window"
"$root/bin/wine" winecfg > "$out/winecfg.log" 2>&1 &
# The loader shows up under its own name, or the program's
seconds=$("$work/wait-window" wine "$limit") || {
    echo "boot-check: no winecfg window within $limit s" >&2
    echo "result=timeout limit=$limit" > "$out/boot.txt"
    exit 1
}
sleep 2
screencapture -x "$out/winecfg.png" || echo "boot-check: screencapture failed" >&2
echo "result=pass seconds=$seconds limit=$limit wine=$("$root/bin/wine" --version)" | tee "$out/boot.txt"
