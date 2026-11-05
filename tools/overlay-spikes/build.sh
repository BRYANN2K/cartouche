#!/bin/sh
# Builds the spike app (Spike.app, an agent app so it has its own TCC identity) and standin.exe
# into out/overlay-spikes, at low priority, one build at a time across agents.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT:-$here/../../out/overlay-spikes}"
mkdir -p "$out"
if [ -z "${CARTOUCHE_BUILD_LOCK_HELD:-}" ]; then
  while ! mkdir /tmp/cartouche-build.lock 2> /dev/null; do sleep 3; done
  trap 'rmdir /tmp/cartouche-build.lock 2> /dev/null' EXIT INT TERM
fi
app="$out/Spike.app/Contents"
mkdir -p "$app/MacOS"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.cartouche.overlay-spike</string>
<key>CFBundleName</key><string>Spike</string>
<key>CFBundleExecutable</key><string>spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
nice -n 15 taskpolicy -b xcrun swiftc -O -swift-version 5 -o "$app/MacOS/spike" "$here/spike.swift"
codesign -s - -f "$out/Spike.app" 2> /dev/null
nice -n 15 taskpolicy -b x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$out/standin.exe" "$here/standin.c" -ld3d11 -ldxgi -luuid
echo "built $out"
