#!/bin/sh
# Builds the pinned innoextract with Boost and liblzma linked statically, so the
# binary needs only system libraries. Usage: build.sh <work dir> <output binary>
# Needs cmake, Boost and xz (CI installs them with Homebrew).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
out=$2
prefix=${HOMEBREW_PREFIX:-/opt/homebrew}

mkdir -p "$work"
fetch() {
    dest=$1 url=$2 sum=$3
    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sum" ]; then return; fi
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    got=$(shasum -a 256 "$dest.part" | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then
        echo "innoextract: $url has sha256 $got, expected $sum" >&2
        rm -f "$dest.part"
        exit 1
    fi
    mv "$dest.part" "$dest"
}

n=0
patches=""
pins=$(grep -v '^#' "$here/pins")
while read -r kind url sum; do
    case "$kind" in
    source) fetch "$work/innoextract.tar.gz" "$url" "$sum" ;;
    patch) n=$((n + 1)); fetch "$work/$n.patch" "$url" "$sum"; patches="$patches $work/$n.patch" ;;
    esac
done <<PINS
$pins
PINS

src="$work/src"
rm -rf "$src" "$work/build"
mkdir -p "$src"
tar -xzf "$work/innoextract.tar.gz" -C "$src" --strip-components 1
for p in $patches; do patch -d "$src" -p1 --forward --quiet < "$p"; done

cmake -S "$src" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DUSE_STATIC_LIBS=ON -DBoost_USE_STATIC_LIBS=ON \
    -DCMAKE_PREFIX_PATH="$prefix/opt/boost;$prefix/opt/xz"
cmake --build "$work/build" --parallel

mkdir -p "$(dirname "$out")"
cp "$work/build/innoextract" "$out"
# Only system libraries may remain, or the app would need Homebrew at run time.
if otool -L "$out" | tail -n +2 | grep -v -E '^[[:space:]]*/(usr/lib|System)/' | grep -q .; then
    echo "innoextract: $out links a non-system library:" >&2
    otool -L "$out" >&2
    exit 1
fi
"$out" --version | head -1
