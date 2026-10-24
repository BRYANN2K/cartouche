#!/bin/sh
# Puts RetroArch.app in Cartouche.app/Contents/Helpers, signs both with the
# same identity, and checks the result.
# usage: embed-retroarch.sh <RetroArch.app> <Cartouche.app> [signing identity]
set -eu

retroarch=${1:?RetroArch.app}
cartouche=${2:?Cartouche.app}
identity=${3:--}

if [ ! -d "$cartouche/Contents/MacOS" ]; then
    echo "embed-retroarch: $cartouche is not an app bundle, run: make app" >&2
    exit 1
fi

helpers="$cartouche/Contents/Helpers"
embedded="$helpers/RetroArch.app"
mkdir -p "$helpers"
rm -rf "$embedded"
ditto "$retroarch" "$embedded"

# Inside out: nested code first, so each signature covers signed contents
if [ -d "$embedded/Contents/Frameworks" ]; then
    find "$embedded/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) |
        while read -r item; do
            codesign -f -s "$identity" --preserve-metadata=identifier,entitlements,flags "$item"
        done
fi
codesign -f -s "$identity" --preserve-metadata=identifier,entitlements,flags "$embedded"
codesign -f -s "$identity" "$cartouche"
codesign --verify --strict --deep "$cartouche"
echo "==> Embedded RetroArch in $embedded, signed with ${identity}"
