#!/bin/sh
# Builds a disk image from a small stand-in app with make-dmg.sh, mounts it
# read-only in a temporary folder and checks what Finder will read: the app,
# the Applications link, the background and the window layout. Also checks the
# wording of the window and of the cask caveats.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
work="$(mktemp -d)"
mnt="$work/mount"
attached=
trap '[ -z "$attached" ] || hdiutil detach -quiet -force "$mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() { echo "dmg-test: $*" >&2; exit 1; }

app="$work/Cartouche.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/Cartouche"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Cartouche</string></dict></plist>\n' \
    > "$app/Contents/Info.plist"

sh "$repo/packaging/dmg/make-dmg.sh" "$app" "$work/Cartouche-0.1.0.dmg" > /dev/null
hdiutil imageinfo "$work/Cartouche-0.1.0.dmg" 2>/dev/null | grep -q 'Format: UDZO' || fail "the image is not compressed read-only (UDZO)"

mkdir "$mnt"
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$work/Cartouche-0.1.0.dmg"
attached=1

[ "$(diskutil info "$mnt" | sed -n 's/^ *Volume Name: *//p')" = Cartouche ] || fail "the volume is not named Cartouche"
cmp -s "$app/Contents/MacOS/Cartouche" "$mnt/Cartouche.app/Contents/MacOS/Cartouche" || fail "the app was not copied"
[ "$(readlink "$mnt/Applications")" = /Applications ] || fail "no link to /Applications"
tiffutil -info "$mnt/.background/background.tiff" 2>&1 | grep -c 'Image Width' | grep -qx 2 \
    || fail "the background does not carry a 1x and a 2x image"

swift -suppress-warnings "$here/dmg-check.swift" "$mnt" > "$work/layout"
sed 's/^/    /' "$work/layout"
picture="$(cd "$mnt" && pwd -P)/.background/background.tiff"
grep -qx ". icvp.backgroundImageAlias -> $picture" "$work/layout" || fail "the background alias does not resolve to the picture"
grep -qx ". pBBk blob bookmark -> $picture" "$work/layout" || fail "the background bookmark does not resolve to the picture"
grep -q '^\. icvp blob .*backgroundType=2 .*iconSize=112 ' "$work/layout" || fail "the icon view does not use the picture"
grep -q 'ShowToolbar=0 .*WindowBounds={{200, 120}, {660, 428}}' "$work/layout" || fail "the window has the wrong size or a toolbar"
grep -qx 'Cartouche.app Iloc blob 170,120' "$work/layout" || fail "Cartouche.app is not where the arrow starts"
grep -qx 'Applications Iloc blob 490,120' "$work/layout" || fail "Applications is not where the arrow points"

hdiutil detach -quiet "$mnt"
attached=

# What the window, the cask and the tap say about the signature
for file in README.md packaging/dmg/background.swift packaging/homebrew/cartouche.rb.in packaging/homebrew/tap-README.md; do
    text="$(tr '\n' ' ' < "$repo/$file" | tr -s ' ')"
    for phrase in "signed with its own certificate" "Open Anyway" "install script"; do
        printf '%s' "$text" | grep -q "$phrase" || fail "$file does not say \"$phrase\""
    done
    if printf '%s' "$text" | grep -qiE 'verified by apple|apple (has )?verified|apple checked'; then
        fail "$file claims Apple checked Cartouche"
    fi
done
grep -q 'does not remove this warning' "$repo/packaging/dmg/background.swift" || fail "the window does not say the certificate keeps the warning"
grep -q 'keeps updates and the permissions' "$repo/packaging/dmg/background.swift" || fail "the window does not say what the certificate is for"
echo "==> dmg-test: the image opens on the three steps, with the app, the Applications link and its background"
