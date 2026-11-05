#!/bin/sh
# Writes the signed appcast for one release into <dir>.
#
#   SPARKLE_PRIVATE_KEY=<key> ./make-appcast.sh <dir> <version> <url prefix> [<channel>] [<critical>]
#   SPARKLE_PRIVATE_KEY=<key> ./make-appcast.sh --announce <dir> <version> <link> [<display version>]
#
# <dir> holds Cartouche-<version>.zip and Cartouche-<version>.html (the release
# notes), and, after the first release, previous-appcast.xml (the published feed)
# and older Cartouche-*.zip archives to make deltas from. It ends up with
# appcast.xml, the new deltas and deltas.txt listing them.
#
# --announce writes no release: it adds an informational item (no archive) on the
# stable channel to previous-appcast.xml, so copies below <version> get a
# dismissable "Learn More…" alert that opens <link>. Cartouche-<version>.html
# holds the short FR/EN notes; <version> is the item's bundle version (pick one
# no real version will equal, like 0.1.2.1) and <display version> the one the
# alert names, like "0.2.0 bêta".
#
# The update window shows <site>/changelog/<version>/sparkle, signed like the
# archive; the embedded notes stay in the item as the fallback (docs/RELEASE.md).
# NOTES_SITE overrides the site; NOTES_SITE=none ships the embedded notes only.
set -eu

if [ "${1:-}" = --announce ]; then
    shift
    dir=${1:?usage: make-appcast.sh --announce <dir> <version> <link> [<display version>]}
    version=${2:?missing version}
    link=${3:?missing link}
    display=${4:-}
    : "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"
    here="$(cd "$(dirname "$0")" && pwd -P)"
    bin=${SPARKLE_BIN:-$here/../app/.build/artifacts/sparkle/Sparkle/bin}
    [ -x "$bin/sign_update" ] || { echo "make-appcast: no Sparkle tools in $bin, run: swift package resolve --package-path app" >&2; exit 1; }
    [ -f "$dir/previous-appcast.xml" ] || { echo "make-appcast: $dir/previous-appcast.xml is missing; download the published feed first" >&2; exit 1; }
    [ -f "$dir/Cartouche-$version.html" ] || { echo "make-appcast: notes $dir/Cartouche-$version.html are missing" >&2; exit 1; }
    cp "$dir/previous-appcast.xml" "$dir/appcast.xml"
    set -- --version "$version" --link "$link" --notes-file "$dir/Cartouche-$version.html"
    if [ -n "$display" ]; then set -- "$@" --display "$display"; fi
    python3 "$here/release.py" announce --appcast "$dir/appcast.xml" "$@"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - "$dir/appcast.xml"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --verify --ed-key-file - "$dir/appcast.xml"
    echo "==> make-appcast: $dir/appcast.xml signed, informational item $version added"
    exit 0
fi

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

notes_site=${NOTES_SITE:-https://cartouche.bryann2k.dev}
if [ "$notes_site" != none ]; then
    url="$(python3 "$here/release.py" notes-url "$version" --site "$notes_site")"
    python3 "$here/release.py" fetch-notes "$version" --url "$url" --out "$work/notes-page.html"
    sig="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - -p --disable-signing-warning "$work/notes-page.html")"
    python3 "$here/release.py" link-notes --appcast "$dir/appcast.xml" \
        --version "$(python3 "$here/release.py" bundle-version "$version")" \
        --url "$url" --signature "$sig" --notes-file "$work/notes-page.html" --full-url "${notes_site%/}/changelog"
    echo "==> make-appcast: release notes linked to $url ($(wc -c < "$work/notes-page.html" | tr -d ' ') bytes)"
fi

printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - "$dir/appcast.xml"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --verify --ed-key-file - "$dir/appcast.xml"
echo "==> make-appcast: $dir/appcast.xml signed, $(wc -l < "$dir/deltas.txt" | tr -d ' ') deltas"
