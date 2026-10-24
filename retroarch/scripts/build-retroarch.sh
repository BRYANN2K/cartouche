#!/bin/sh
# Builds RetroArch.app from the pinned submodule with its Xcode project, then
# checks it names the commit and serves MCP.
# usage: build-retroarch.sh <derived data folder> <output folder>
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
src="$root/vendor/RetroArch"
derived=${1:?derived data folder}
out=${2:?output folder}

pinned=$(git -C "$root" ls-tree HEAD vendor/RetroArch | awk '{ print $3 }')
if [ -z "$pinned" ]; then
    echo "build-retroarch: vendor/RetroArch is not a submodule at HEAD" >&2
    exit 1
fi
checked=$(git -C "$src" rev-parse HEAD 2>/dev/null || true)
if [ "$checked" != "$pinned" ]; then
    echo "build-retroarch: vendor/RetroArch is at ${checked:-nothing}, the pin is $pinned." >&2
    echo "run: git submodule update --init --depth 1 vendor/RetroArch" >&2
    exit 1
fi
# What ships must be the source we offer
if [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then
    echo "build-retroarch: vendor/RetroArch has local changes" >&2
    git -C "$src" status --short --untracked-files=no >&2
    exit 1
fi

# The project's 10.13 is below what Xcode 27 builds for, and the xcconfig
# does not reach the project level where it is set
xcodebuild \
    -workspace "$src/pkg/apple/RetroArch.xcworkspace" \
    -scheme RetroArch \
    -configuration Release \
    -xcconfig "$root/retroarch/xcode/Cartouche.xcconfig" \
    -derivedDataPath "$derived" \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGN_IDENTITY=- \
    build

app="$derived/Build/Products/Release/RetroArch.app"
sh "$root/retroarch/scripts/check-retroarch.sh" "$app" "$pinned"

mkdir -p "$out"
rm -rf "$out/RetroArch.app"
ditto "$app" "$out/RetroArch.app"
echo "$pinned" > "$out/RetroArch.commit"
echo "==> Built $out/RetroArch.app from $pinned"
