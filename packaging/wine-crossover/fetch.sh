#!/bin/sh
# Downloads one pinned file and keeps it only if its SHA-256 matches.
#
#   ./fetch.sh <url> <sha256> <destination file>
#
# An existing destination with the right hash is reused. A mismatch deletes
# what was downloaded and exits 1.
set -eu

[ $# -eq 3 ] || { echo "usage: fetch.sh <url> <sha256> <destination file>" >&2; exit 2; }
url=$1 want=$2 dest=$3

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -f "$dest" ] && [ "$(sha256 "$dest")" = "$want" ]; then
    echo "==> fetch: reusing $dest"
    exit 0
fi

mkdir -p "$(dirname "$dest")"
part="$dest.part"
rm -f "$part"
trap 'rm -f "$part"' EXIT
curl -fL --retry 3 --silent --show-error -o "$part" "$url"
got=$(sha256 "$part")
if [ "$got" != "$want" ]; then
    echo "fetch: $url has SHA-256 $got, the pin is $want" >&2
    exit 1
fi
mv "$part" "$dest"
echo "==> fetch: $dest verified"
