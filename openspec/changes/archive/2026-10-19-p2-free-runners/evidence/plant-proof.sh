#!/bin/sh
# Plants a real Game Porting Toolkit file (under a Wine name) in a scratch tree, scans, removes it, scans again
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
src=${1:?usage: plant-proof.sh <lib folder of your own GPTK copy>}
w=/tmp/p2/plant
rm -rf "$w"; mkdir -p "$w/tree/lib/wine/x86_64-windows"
cp "$src/wine/x86_64-windows/d3d12.dll" "$w/tree/lib/wine/x86_64-windows/d3d12.dll"
cp "$src/external/libd3dshared.dylib" "$w/tree/lib/wine/x86_64-windows/renamed.dll"
echo "== planted (Apple's d3d12.dll, and libd3dshared.dylib renamed)"
sh "$repo/packaging/redist-scan.sh" "$w/tree"; echo "exit $?"
(cd "$w" && tar -cJf planted.tar.xz tree)
sh "$repo/packaging/redist-scan.sh" "$w/planted.tar.xz"; echo "exit $?"
rm -f "$w/tree/lib/wine/x86_64-windows/d3d12.dll" "$w/tree/lib/wine/x86_64-windows/renamed.dll"
echo "== removed"
sh "$repo/packaging/redist-scan.sh" "$w/tree"; echo "exit $?"
rm -rf "$w"
echo "== repository"
cd "$repo" && time sh packaging/redist-scan.sh .; echo "exit $?"
