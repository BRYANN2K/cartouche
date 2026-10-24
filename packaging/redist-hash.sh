#!/bin/sh
# Prints redist-hashes.txt lines for every file of a Game Porting Toolkit copy,
# so a new version can be added to the redistribution scan. Reads only.
#
#   ./redist-hash.sh <label> <folder>      e.g. gptk-4.0b3 ".../redist/lib"
set -eu

[ $# -eq 2 ] || { echo "usage: redist-hash.sh <label> <folder>" >&2; exit 2; }
label=$1
cd "$2"
find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
    size=$(wc -c < "$f" | tr -d ' ')
    echo "$sum $size $label/${f#./}"
done
