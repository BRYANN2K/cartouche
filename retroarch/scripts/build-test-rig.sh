#!/bin/sh
# Builds a command-line RetroArch from the pinned submodule for the MCP tests.
# Same source and MCP server as the app, but made with ./configure and no Metal
# shaders, so it needs neither the Xcode project nor the Metal toolchain.
# usage: build-test-rig.sh <output folder>
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:?output folder}
src="$out/src"

pinned=$(git -C "$root" ls-tree HEAD vendor/RetroArch | awk '{ print $3 }')
short=$(printf '%s' "$pinned" | cut -c1-7)
if [ ! -f "$root/vendor/RetroArch/retroarch.c" ]; then
    echo "build-test-rig: vendor/RetroArch is not checked out" >&2
    exit 1
fi

if [ -x "$out/retroarch" ] && [ "$(cat "$out/retroarch.commit" 2>/dev/null)" = "$pinned" ]; then
    echo "==> Test rig already built for $short"
    exit 0
fi

mkdir -p "$src"
rsync -a --delete --exclude .git "$root/vendor/RetroArch/" "$src/"
(
    cd "$src"
    ./configure --disable-qt --disable-ffmpeg --disable-discord --disable-sdl2 \
        --disable-sdl --disable-cheevos --disable-metal >/dev/null
    grep -q '^HAVE_MCP = 1' config.mk
    make -j"$(sysctl -n hw.ncpu)" GIT_VERSION="$short" >/dev/null
)
cp "$src/retroarch" "$out/retroarch"
echo "$pinned" > "$out/retroarch.commit"
sh "$root/retroarch/scripts/check-retroarch.sh" "$out/retroarch" "$pinned"
