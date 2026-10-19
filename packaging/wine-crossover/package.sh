#!/bin/sh
# Turns a Wine CrossOver install tree into the release asset: one tar.xz with the
# LGPL notices and the source offer inside, its .sha256, and the runner manifest
# entry the app pins it with.
#
#   ./package.sh <install folder> <source tarball> <out folder>
#
# REPOSITORY (owner/name) sets the download URL, GITHUB_SHA the recorded commit.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
. "${PINS_FILE:-$here/pins.env}"

[ $# -eq 3 ] || { echo "usage: package.sh <install folder> <source tarball> <out folder>" >&2; exit 2; }
install=$1 source_tar=$2 out=$3
repository=${REPOSITORY:-BRYANN2K/cartouche}
commit=${GITHUB_SHA:-$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)}

[ -x "$install/bin/wine" ] || { echo "package.sh: $install/bin/wine is missing" >&2; exit 1; }
[ "$(shasum -a 256 "$source_tar" | cut -d' ' -f1)" = "$CX_SOURCE_SHA256" ] \
    || { echo "package.sh: $source_tar is not the pinned source tarball" >&2; exit 1; }

name="wine-crossover-$CX_VERSION-$BUILD_REVISION"
tag=$name
asset="$name-x86_64.tar.xz"
display=$(echo "$CX_VERSION" | sed -E 's/^([0-9]+\.[0-9]+)\.0$/\1/')

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root="$stage/$name"
mkdir -p "$root" "$out"
cp -R "$install/." "$root/"

# The notices travel with the binaries
tar -xzf "$source_tar" -C "$stage" sources/wine/LICENSE sources/wine/COPYING.LIB sources/wine/AUTHORS
mv "$stage/sources/wine/LICENSE" "$stage/sources/wine/COPYING.LIB" "$stage/sources/wine/AUTHORS" "$root/"
rm -rf "$stage/sources"

cat > "$root/SOURCE.md" <<EOF
# Source code for this build

This is Wine as published by CodeWeavers in the CrossOver $CX_VERSION sources,
built by Cartouche. It is free software under the GNU Lesser General Public
License, version 2.1 or later (COPYING.LIB, LICENSE, AUTHORS).

It is not CrossOver and is not made or supported by CodeWeavers.

- Source tarball: $CX_SOURCE_URL
- Its SHA-256: $CX_SOURCE_SHA256
- A copy of that tarball is attached to the same release as this archive:
  https://github.com/$repository/releases/tag/$tag
- Build scripts: https://github.com/$repository/tree/$commit/packaging/wine-crossover
- Toolchain: Xcode at $XCODE_APP, llvm-mingw $LLVM_MINGW_VERSION, macOS $MACOSX_DEPLOYMENT_TARGET target,
  Homebrew $BREW_BUILD_DEPS $BREW_LINK_DEPS (versions in BUILDINFO.txt)
EOF

{
    echo "cx_version=$CX_VERSION"
    echo "build_revision=$BUILD_REVISION"
    echo "commit=$commit"
    echo "llvm_mingw=$LLVM_MINGW_VERSION"
    if command -v brew >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        brew list --versions $BREW_BUILD_DEPS $BREW_LINK_DEPS 2>/dev/null | sed 's/^/brew: /'
    fi
    if command -v xcodebuild >/dev/null 2>&1; then xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/^/xcode: /'; echo; fi
} > "$root/BUILDINFO.txt"

# Owner and order do not depend on the build machine
(cd "$stage" && find "$name" -print | LC_ALL=C sort > "$stage/files" \
    && tar --uid 0 --gid 0 --uname root --gname wheel -cf - -n -T "$stage/files" | xz -9e -T0 > "$out/$asset")

(cd "$out" && shasum -a 256 "$asset" > "$asset.sha256")
python3 "$here/manifest_entry.py" "$out/$asset" \
    --id "$name" --url "https://github.com/$repository/releases/download/$tag/$asset" \
    --root "$name" --version "$CX_VERSION" --display-version "$display" > "$out/manifest-entry.json"
echo "$tag" > "$out/tag"
echo "==> package: $out/$asset ($(wc -c < "$out/$asset" | tr -d ' ') bytes)"
