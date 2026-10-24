#!/bin/sh
# Checks that a RetroArch build is the one Cartouche pins: its --version names
# the commit, and it offers --mcp-stdio.
# usage: check-retroarch.sh <RetroArch.app or binary> <commit>
set -eu

target=${1:?RetroArch.app or a retroarch binary}
commit=${2:?the pinned commit}

case $target in
    *.app) exe="$target/Contents/MacOS/RetroArch" ;;
    *) exe=$target ;;
esac
if [ ! -x "$exe" ]; then
    echo "check-retroarch: no RetroArch executable at $exe" >&2
    exit 1
fi

# A home of its own: RetroArch makes folders under ~ as it starts, and macOS
# RetroArch finds ~ through Foundation, which reads CFFIXED_USER_HOME, not HOME
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-retroarch.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch" CFFIXED_USER_HOME="$scratch"

# A GUI build that does not exit after printing must not hang the job
bounded() { perl -e 'alarm shift; exec @ARGV' 60 "$@"; }

version=$(bounded "$exe" --version 2>&1 || true)
git=$(printf '%s\n' "$version" | sed -n 's/.*(Git \([0-9a-f]\{7,\}\)).*/\1/p' | head -n 1)
if [ -z "$git" ]; then
    echo "check-retroarch: --version names no commit:" >&2
    printf '%s\n' "$version" | sed 's/^/    /' >&2
    exit 1
fi
case $commit in
    "$git"*) ;;
    *)
        echo "check-retroarch: --version names $git, the pin is $commit" >&2
        exit 1
        ;;
esac

if ! bounded "$exe" --help 2>&1 | grep -q -- '--mcp-stdio'; then
    echo "check-retroarch: $exe has no --mcp-stdio, it was built without HAVE_MCP" >&2
    exit 1
fi

echo "==> $(printf '%s\n' "$version" | sed -n 's/^Version: //p' | head -n 1), commit $git, serves --mcp-stdio"
