#!/bin/sh
# Checks that the page the update window shows still matches the appcast:
# a 200 for the right version, the signed length and the signed bytes.
# Run before publishing a release, and after every site deploy.
#
#   SPARKLE_PRIVATE_KEY=<key> ./check-release-notes.sh <appcast.xml> [<bundle version>]
set -eu

appcast=${1:?usage: check-release-notes.sh <appcast.xml> [<bundle version>]}
here="$(cd "$(dirname "$0")" && pwd -P)"
bin=${SPARKLE_BIN:-$here/../app/.build/artifacts/sparkle/Sparkle/bin}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

if [ -n "${2:-}" ]; then set -- --version "$2"; else set --; fi
link=$(python3 "$here/release.py" notes-link-of "$appcast" "$@")
# shellcheck disable=SC2086 # notes-link-of prints a "url sig length" triple, split on purpose
set -- $link
url=$1 sig=$2 length=$3
version=$(printf '%s' "$url" | sed -n 's|.*/changelog/\([^/]*\)/sparkle$|\1|p')
[ -n "$version" ] || { echo "check-release-notes: $url is not a /changelog/<version>/sparkle page" >&2; exit 1; }

page="$(mktemp)"
trap 'rm -f "$page"' EXIT
python3 "$here/release.py" fetch-notes "$version" --url "$url" --out "$page"
got=$(wc -c < "$page" | tr -d ' ')
[ "$got" = "$length" ] || { echo "check-release-notes: $url is $got bytes, the appcast signed $length; the page changed since the release" >&2; exit 1; }
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$bin/sign_update" --verify --ed-key-file - "$page" "$sig" >/dev/null \
    || { echo "check-release-notes: $url does not match its signature; the page changed since the release" >&2; exit 1; }
echo "==> check-release-notes: $url answers 200 and matches the appcast"
