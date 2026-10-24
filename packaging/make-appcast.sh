#!/bin/sh
# Writes the signed appcast for one release into <dir>.
#
#   SPARKLE_PRIVATE_KEY=<key> ./make-appcast.sh <dir> <version> <url prefix> [<channel>] [<critical>]
#
# <dir> holds Cartouche-<version>.zip and Cartouche-<version>.html (the release
# notes), and, after the first release, previous-appcast.xml (the published feed)
# and older Cartouche-*.zip archives to make deltas from. It ends up with
# appcast.xml, the new deltas and deltas.txt listing them.
set -eu

dir=${1:?usage: make-appcast.sh <dir> <version> <url prefix> [<channel>] [<critical>]}
version=${2:?missing version}
prefix=${3:?missing url prefix}
channel=${4:-}
critical=${5:-false}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

here="$(cd "$(dirname "$0")" && pwd -P)"
bin=${SPARKLE_BIN:-$here/../app/.build/artifacts/sparkle/Sparkle/bin}
[ -x "$bin/generate_appcast" ] || { echo "make-appcast: no Sparkle tools in $bin, run: swift package resolve --package-path app" >&2; exit 1; }
[ -f "$dir/Cartouche-$version.zip" ] || { echo "make-appcast: $dir/Cartouche-$version.zip is missing" >&2; exit 1; }
[ -f "$dir/Cartouche-$version.html" ] || { echo "make-appcast: release notes $dir/Cartouche-$version.html are missing" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$dir"/Cartouche-*.zip "$dir/Cartouche-$version.html" "$work/"

set -- --ed-key-file - --download-url-prefix "$prefix" --embed-release-notes \
    --maximum-deltas 3 --maximum-versions 0
if [ -n "$channel" ]; then set -- "$@" --channel "$channel"; fi
# An empty version makes the update critical whatever version is installed
if [ "$critical" = true ]; then set -- "$@" --critical-update-version ""; fi
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/generate_appcast" "$@" "$work"

if [ -f "$dir/previous-appcast.xml" ]; then
    set -- --previous "$dir/previous-appcast.xml"
else
    set --
fi
python3 "$here/release.py" merge-appcast "$@" --generated "$work/appcast.xml" \
    --version "$(python3 "$here/release.py" bundle-version "$version")" --archive "Cartouche-$version.zip" \
    --url-prefix "$prefix" --out "$dir/appcast.xml" --deltas-out "$dir/deltas.txt"
while IFS= read -r delta; do
    cp "$work/$delta" "$dir/"
done < "$dir/deltas.txt"

printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - "$dir/appcast.xml"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --verify --ed-key-file - "$dir/appcast.xml"
echo "==> make-appcast: $dir/appcast.xml signed, $(wc -l < "$dir/deltas.txt" | tr -d ' ') deltas"
