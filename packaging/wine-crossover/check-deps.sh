#!/bin/sh
# Fails when a Mach-O file in the package loads a library from outside macOS and
# the package itself, or searches a build machine folder. A runner that only
# works where Homebrew is installed would pass every check on CI and fail on
# the user's Mac.
#
#   ./check-deps.sh <package root>
set -eu

[ $# -eq 1 ] || { echo "usage: check-deps.sh <package root>" >&2; exit 2; }
root=$1
bad=$(mktemp)
trap 'rm -f "$bad"' EXIT

find "$root" -type f | while IFS= read -r f; do
    file -b "$f" | grep -q '^Mach-O' || continue
    otool -L "$f" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' | while IFS= read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
            *) echo "$f loads $dep" >> "$bad" ;;
        esac
    done
    otool -l "$f" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | while IFS= read -r path; do
        case "$path" in
            @*) ;;
            *) echo "$f searches $path" >> "$bad" ;;
        esac
    done
done

if [ -s "$bad" ]; then
    echo "check-deps: the package depends on files outside it:" >&2
    sed 's/^/    /' "$bad" >&2
    exit 1
fi
echo "==> check-deps: every Mach-O file in $root loads only macOS and package libraries"
