#!/bin/sh
# scan-binaries.sh must fail on a planted core, whatever its name, and pass a
# repository whose only Mach-O is not RetroArch's.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
scan="$here/../scripts/scan-binaries.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fresh_repo() {
    rm -rf "$work/repo"
    mkdir -p "$work/repo"
    git -C "$work/repo" init -q
    git -C "$work/repo" config user.email scan@example.invalid
    git -C "$work/repo" config user.name scan
    echo "readme" > "$work/repo/README"
    git -C "$work/repo" add README
}

# Something that only looks like a libretro core in the symbol it exports
cat > "$work/core.c" <<'EOF'
unsigned retro_api_version(void) { return 1; }
EOF
cat > "$work/helper.c" <<'EOF'
int helper_answer(void) { return 42; }
EOF
xcrun clang -dynamiclib -o "$work/core.dylib" "$work/core.c"
xcrun clang -dynamiclib -o "$work/helper.dylib" "$work/helper.c"

expect_fail() {
    label=$1
    if out=$(sh "$scan" "$work/repo" 2>&1); then
        echo "scancheck: $label: the scan passed" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if ! printf '%s\n' "$out" | grep -qF "$2"; then
        echo "scancheck: $label: the scan failed without naming $2" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    echo "==> scancheck: $label is caught"
}

# A core under its buildbot name
fresh_repo
cp "$work/core.dylib" "$work/repo/snes9x_libretro.dylib"
git -C "$work/repo" add -f snes9x_libretro.dylib
expect_fail "a core named as the buildbot names it" "snes9x_libretro.dylib"

# The same core renamed so that no name rule matches
fresh_repo
cp "$work/core.dylib" "$work/repo/innocent.bin"
git -C "$work/repo" add -f innocent.bin
expect_fail "a renamed core" "innocent.bin"

# A zipped core as the buildbot serves it
fresh_repo
cp "$work/core.dylib" "$work/repo/genesis_plus_gx_libretro.dylib"
(cd "$work/repo" && zip -q genesis_plus_gx_libretro.dylib.zip genesis_plus_gx_libretro.dylib && rm genesis_plus_gx_libretro.dylib)
git -C "$work/repo" add -f genesis_plus_gx_libretro.dylib.zip
expect_fail "a zipped core" "genesis_plus_gx_libretro.dylib.zip"

# A RetroArch bundle
fresh_repo
mkdir -p "$work/repo/RetroArch.app/Contents/MacOS"
cp "$work/helper.dylib" "$work/repo/RetroArch.app/Contents/MacOS/RetroArch"
git -C "$work/repo" add -f RetroArch.app
expect_fail "a RetroArch bundle" "RetroArch.app/Contents/MacOS/RetroArch"

# A Mach-O that is neither passes
fresh_repo
cp "$work/helper.dylib" "$work/repo/helper.bin"
git -C "$work/repo" add -f helper.bin
if ! sh "$scan" "$work/repo" >/dev/null; then
    echo "scancheck: a Mach-O that is not RetroArch's was refused" >&2
    exit 1
fi
echo "==> scancheck: an unrelated Mach-O passes"
