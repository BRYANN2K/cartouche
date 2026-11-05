#!/bin/sh
# Static analysis of the shipped C and Objective-C: clang --analyze, then cppcheck. Every
# finding fails unless tools/c-safety/analyze-baseline.txt accepts it, with a reason.
#
#   tools/c-safety/analyze.sh <out dir> <generated include dir>
#
# Not analysed, each for a reason in docs/ci/C-SAFETY.md: vendor/ (cJSON, Dobby,
# RetroArch), steam-shim/json and jsoncpp.cpp (jsoncpp), framegen/proxy/ffx (AMD headers),
# lsteamclient/ (Proton's lsteamclient, built in the Wine tree), the tests.
# shellcheck disable=SC2086,SC2129 # flag and source lists split on purpose; findings collect in one file
set -u

out=$1
generated=$2
here=$(cd "$(dirname "$0")" && pwd)
baseline="$here/analyze-baseline.txt"
mkdir -p "$out"
found="$out/findings.txt"
: > "$found"
: > "$out/clang-all.log"

identity=app/Sources/CartoucheIdentity/include
mac="-arch arm64 -mmacosx-version-min=15.0 -Idylib -I$identity -I$generated -Ivendor"
mingw=$(brew --prefix mingw-w64 2>/dev/null)
win64=$mingw/toolchain-x86_64/x86_64-w64-mingw32/include
win32=$mingw/toolchain-i686/i686-w64-mingw32/include

dylib_c=${DYLIB_SRCS:?the Makefile passes the dylib sources}
fg_objc="framegen/framegen.m framegen/fg_pipeline.m framegen/fg_ane.m framegen/fg_bridge.m
         framegen/fg_upscale.m framegen/fg_temporal.m framegen/fg_metal.m framegen/fg_proxy.m
         framegen/fg_metrics.m framegen/fg_overlay.m"

# clang --analyze, one group of sources per set of flags. Findings land as
# "file<TAB>checker<TAB>message", without the line, so moving code keeps the baseline.
analyze() {
  flags=$1; shift
  for f in "$@"; do
    xcrun clang --analyze -Xanalyzer -analyzer-output=text \
      -Xanalyzer -analyzer-checker=security.insecureAPI.strcpy \
      $flags -o /dev/null "$f" > "$out/clang.log" 2>&1
    cat "$out/clang.log" >> "$out/clang-all.log"
    perl -ne 'print "clang\t$1\t$3\t$2\n" if /^([^:]+):\d+:\d+: warning: (.*) \[([\w.]+)\]$/' \
      "$out/clang.log" >> "$found"
    grep -q ': error:' "$out/clang.log" && { echo "  clang cannot build $f:"; grep ': error:' "$out/clang.log" | head -5; echo "clang	$f	build	does not compile" >> "$found"; }
  done
}

analyze "$mac -std=c17" $dylib_c helpers/shortcuts.c
analyze "$mac -std=c17" framegen/bridge/cartouche_bridge_unix.c framegen/proxy/ffx_proxy_unix.c
analyze "-arch arm64 -mmacosx-version-min=15.0" overlay-shim/overlay_shim.m fps-counter/fps_counter.m
analyze "-arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -I$out/../framegen" $fg_objc
analyze "-arch arm64 -mmacosx-version-min=15.0 -fobjc-arc" framegen/ane/helper.m
if [ -d "$win64" ]; then
  analyze "--target=x86_64-w64-mingw32 -isystem $win64 -Wno-unknown-pragmas" \
    framegen/bridge/cartouche_bridge.c framegen/proxy/ffx_proxy.c helpers/game-restore.c
  analyze "--target=x86_64-w64-mingw32 -ffreestanding" ntdll-patch/detour.c
  analyze "--target=i686-w64-mingw32 -isystem $win32" helpers/unarc-driver.c
  # The slots come from resolve.py at build time (build32.sh); any value parses
  analyze "--target=i686-w64-mingw32 -ffreestanding -DFLAGS_SLOT=0 -DFLAGS_BIT=0 -DLOAD_PATH_SLOT=0" \
    ntdll-patch/detour32.c
else
  echo "  skip  clang --analyze of the Windows sources: mingw-w64 headers not found (brew install mingw-w64)"
fi
if [ -d steam-shim/proton-headers ]; then
  echo "  note  steam-shim/steam.cpp: analysed by cppcheck only, it builds as a winelib in the Wine tree"
fi

# cppcheck reads C and C++ only, so the Objective-C stays with clang above
if command -v cppcheck > /dev/null 2>&1; then
  cppcheck --enable=warning,portability,performance --inline-suppr --error-exitcode=0 \
    --std=c17 --platform=unix64 --library=posix -D__APPLE__ -D__aarch64__ -D__arm64__ \
    -Idylib -I"$identity" -I"$generated" --suppress=missingIncludeSystem \
    --template='cppcheck\t{file}\t{id}\t{message}' -q \
    $dylib_c helpers/shortcuts.c framegen/bridge/cartouche_bridge_unix.c framegen/proxy/ffx_proxy_unix.c \
    2>> "$found"
  cppcheck --enable=warning,portability,performance --inline-suppr --error-exitcode=0 \
    --std=c23 --platform=win64 --library=windows -D_WIN32 -D_WIN64 -D__x86_64__ \
    --suppress=missingIncludeSystem --template='cppcheck\t{file}\t{id}\t{message}' -q \
    framegen/bridge/cartouche_bridge.c framegen/proxy/ffx_proxy.c helpers/game-restore.c \
    ntdll-patch/detour.c 2>> "$found"
  cppcheck --enable=warning,portability,performance --inline-suppr --error-exitcode=0 \
    --std=c17 --platform=win32A --library=windows -D_WIN32 -D__i386__ \
    --suppress=missingIncludeSystem --template='cppcheck\t{file}\t{id}\t{message}' -q \
    helpers/unarc-driver.c ntdll-patch/detour32.c 2>> "$found"
  cppcheck --enable=warning,portability,performance --inline-suppr --error-exitcode=0 \
    --std=c++17 --language=c++ --platform=unix64 --library=posix -D__x86_64__ \
    --suppress=missingIncludeSystem --suppress=missingInclude --suppress='*:steam-shim/json/*' \
    --template='cppcheck\t{file}\t{id}\t{message}' -q steam-shim/steam.cpp 2>> "$found"
else
  echo "  FAIL  cppcheck not found (brew install cppcheck)"
  exit 1
fi

# The baseline holds "tool<TAB>file<TAB>check<TAB>message<TAB>reason"; # starts a comment
sort -u "$found" -o "$found"
grep -v '^#' "$baseline" | grep -v '^$' | cut -f1-4 | sort -u > "$out/accepted.txt"
new=$(comm -23 "$found" "$out/accepted.txt")
stale=$(comm -13 "$found" "$out/accepted.txt")
total=$(grep -c . "$found")
if [ -n "$stale" ]; then
  echo "  note  baseline entries nothing reports any more, remove them:"
  echo "$stale" | sed 's/^/        /'
fi
if [ -n "$new" ]; then
  echo "  FAIL  findings not in tools/c-safety/analyze-baseline.txt:"
  echo "$new" | sed 's/^/        /'
  echo "        details: $out/clang-all.log"
  exit 1
fi
echo "==> c-analyze: clang --analyze and cppcheck clean ($total accepted in the baseline)"
