#!/bin/sh
# Builds the pinned libarchive as a universal (arm64 + x86_64) dylib for
# Cartouche.app/Contents/Helpers. liblzma and zstd are built from the pinned
# sources and linked in statically, so the dylib needs only system libraries
# at run time. Usage: build.sh <work dir> <output dylib>
# Needs cmake and the Xcode command line tools; the app workflow installs cmake
# with Homebrew when the runner lacks it.
set -eu

for tool in cmake curl lipo otool install_name_tool; do
    command -v "$tool" >/dev/null 2>&1 || { echo "libarchive: '$tool' is required (install Xcode CLT and cmake)" >&2; exit 1; }
done

here=$(cd "$(dirname "$0")" && pwd)
work=$1
out=$2

mkdir -p "$work"
fetch() {
    dest=$1 url=$2 sum=$3
    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sum" ]; then return; fi
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    got=$(shasum -a 256 "$dest.part" | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then
        echo "libarchive: $url has sha256 $got, expected $sum" >&2
        rm -f "$dest.part"
        exit 1
    fi
    mv "$dest.part" "$dest"
}

pins=$(grep -v '^#' "$here/pins")
while read -r name url sum; do
    fetch "$work/$name.tar.gz" "$url" "$sum"
done <<PINS
$pins
PINS

unpack() {
    src=$1
    rm -rf "$src"
    mkdir -p "$src"
    tar -xzf "$work/$2.tar.gz" -C "$src" --strip-components 1
}

unpack "$work/src-xz" xz
unpack "$work/src-zstd" zstd
unpack "$work/src-libarchive" libarchive

ARCHES='arm64;x86_64'
cmake_build() {
    cmake -S "$1" -B "$2" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES="$ARCHES" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON ${3:+$3}
    cmake --build "$2" --parallel --target "$4"
}

# liblzma, static and universal; only the library, not the xz tools.
cmake_build "$work/src-xz" "$work/build-xz" "-DBUILD_SHARED_LIBS=OFF -DENABLE_NLS=OFF -DENABLE_DOXYGEN=OFF" liblzma
lzma_a=$(find "$work/build-xz" -name 'liblzma.a' | head -1)

# zstd, static and universal; the library only.
cmake_build "$work/src-zstd/build/cmake" "$work/build-zstd" \
    "-DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF" libzstd_static
zstd_a=$(find "$work/build-zstd" -name 'libzstd.a' | head -1)

cmake -S "$work/src-libarchive" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES="$ARCHES" \
    -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_NETTLE=OFF -DENABLE_MBEDTLS=OFF -DENABLE_CNG=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF \
    -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF \
    -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_ICONV=ON \
    -DENABLE_LZMA=ON -DLIBLZMA_INCLUDE_DIR="$work/src-xz/src/liblzma/api" -DLIBLZMA_LIBRARY="$lzma_a" \
    -DENABLE_ZSTD=ON -DZSTD_INCLUDE_DIR="$work/src-zstd/lib" -DZSTD_LIBRARY="$zstd_a"
cmake --build "$work/build" --parallel --target archive

dylib=$(find "$work/build" -name 'libarchive.*.dylib' ! -type l | head -1)
mkdir -p "$(dirname "$out")"
cp "$dylib" "$out"
install_name_tool -id "@rpath/libarchive.dylib" "$out"

# Universal, or the app cannot run native on Intel.
if ! lipo -info "$out" | grep -q 'x86_64' || ! lipo -info "$out" | grep -q 'arm64'; then
    echo "libarchive: $out is not universal:" >&2
    lipo -info "$out" >&2
    exit 1
fi
# Only system libraries may remain, or the app would need Homebrew at run time.
# Dep lines are tab-indented; the fat-binary header lines are not.
if otool -L "$out" | grep -E '^[[:space:]]+/' | grep -v -E '^[[:space:]]+/(usr/lib|System)/' | grep -q .; then
    echo "libarchive: $out links a non-system library:" >&2
    otool -L "$out" >&2
    exit 1
fi
otool -L "$out" | tail -n +2
