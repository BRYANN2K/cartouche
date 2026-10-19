#!/bin/sh
# Builds the disk image: Cartouche, a link to Applications, and a window that
# shows the three steps of the first open (docs/RELEASE.md).
#
#   ./make-dmg.sh <Cartouche.app> <out.dmg>
#
# The window layout is written by layout.swift, not by Finder, so this needs no
# Automation permission. The image is mounted only inside a temporary folder.
set -eu

app=${1:?usage: make-dmg.sh <Cartouche.app> <out.dmg>}
out=${2:?usage: make-dmg.sh <Cartouche.app> <out.dmg>}
name=Cartouche

here="$(cd "$(dirname "$0")" && pwd -P)"
[ -d "$app/Contents" ] || { echo "make-dmg: $app is not an app bundle" >&2; exit 1; }

work="$(mktemp -d)"
mnt="$work/mount"
attached=
cleanup() {
    if [ -n "$attached" ]; then hdiutil detach -quiet -force "$mnt" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# Room for the app, the background and HFS+ overhead
size=$(( $(du -sk "$app" | cut -f1) / 1024 + 20 ))
hdiutil create -quiet -size "${size}m" -fs HFS+ -volname "$name" "$work/rw.dmg"
mkdir "$mnt"
hdiutil attach -quiet -nobrowse -noautoopen -noverify -mountpoint "$mnt" "$work/rw.dmg"
attached=1

ditto "$app" "$mnt/Cartouche.app"
ln -s /Applications "$mnt/Applications"
mkdir "$mnt/.background"
tiffutil -cathidpicheck "$here/background.png" "$here/background@2x.png" -out "$mnt/.background/background.tiff" 2>/dev/null
# Icon centers match background.swift's arrow
swift "$here/layout.swift" "$mnt" "Cartouche.app=170,120" "Applications=490,120"

hdiutil detach -quiet "$mnt"
attached=
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
echo "==> make-dmg: $out"
