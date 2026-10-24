#!/bin/sh
# sdl2-compat loads SDL3 at runtime; otool and wine --version cannot check it.
set -eu
here="$(cd "$(dirname "$0")" && pwd -P)"
[ $# -eq 1 ] || { echo "usage: check-sdl.sh <runner root>" >&2; exit 2; }
root=$(cd "$1" && pwd -P)
for lib in libSDL2-2.0.0.dylib libSDL3.dylib; do
    [ -f "$root/lib/$lib" ] || { echo "check-sdl: missing $lib" >&2; exit 1; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The runner is x86_64 even on Apple Silicon.
cc -arch x86_64 "$here/check-sdl.c" -o "$work/check-sdl"
"$work/check-sdl" "$root/lib/libSDL2-2.0.0.dylib"
