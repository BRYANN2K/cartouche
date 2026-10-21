#!/bin/sh
# Checks a packaged Wine CrossOver the way the app will get it: the archive
# matches its .sha256, unpacks into one folder with the notices, depends on
# nothing outside itself, and its wine runs.
#
#   ./verify.sh <archive.tar.xz>
#
# Prints the output of `wine --version` last.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
[ $# -eq 1 ] || { echo "usage: verify.sh <archive.tar.xz>" >&2; exit 2; }
archive=$1
fail() { echo "verify: $*" >&2; exit 1; }

[ -f "$archive.sha256" ] || fail "$archive.sha256 is missing"
want=$(cut -d' ' -f1 "$archive.sha256")
got=$(shasum -a 256 "$archive" | cut -d' ' -f1)
[ "$got" = "$want" ] || fail "$archive has SHA-256 $got, $archive.sha256 says $want"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xJf "$archive" -C "$work"
roots=$(ls "$work")
[ "$(echo "$roots" | wc -l | tr -d ' ')" = 1 ] || fail "the archive has more than one top folder: $roots"
root="$work/$roots"
for f in bin/wine bin/wineserver lib/wine/x86_64-unix/wine share/wine/wine.inf \
    LICENSE COPYING.LIB SOURCE.md; do
    [ -e "$root/$f" ] || fail "$roots/$f is missing"
done
for arch in x86_64-windows i386-windows; do
    [ -f "$root/lib/wine/$arch/ntdll.dll" ] || fail "$roots/lib/wine/$arch/ntdll.dll is missing"
done
sh "$here/check-deps.sh" "$root"
sh "$here/check-sdl.sh" "$root"

# A scratch home, so nothing from this machine's Wine setup is read
home="$work/home"
mkdir -p "$home"
version=$(env -i HOME="$home" PATH=/usr/bin:/bin WINEDEBUG=-all "$root/bin/wine" --version) \
    || fail "wine --version exited $?"
case "$version" in
    wine-*) ;;
    *) fail "wine --version printed '$version'" ;;
esac
echo "==> verify: $roots ok"
echo "$version"
