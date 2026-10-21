#!/bin/sh
# Builds the pinned innoextract with Boost and liblzma linked statically, so the
# binary needs only system libraries. Both dependencies are built universal
# (arm64 + x86_64) from the pinned sources in pins, then innoextract is too.
# Usage: build.sh <work dir> <output binary>. Needs cmake and a C++ toolchain.
set -eu

for tool in cmake curl patch tar xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "innoextract: '$tool' is required (install Xcode CLT and cmake)" >&2; exit 1; }
done

here=$(cd "$(dirname "$0")" && pwd)
work=$1
out=$2
arches="arm64;x86_64"
minver=15.0
sdk=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$work"
work=$(cd "$work" && pwd)
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
    boost) fetch "$work/boost.tar.gz" "$url" "$sum" ;;
    xz) fetch "$work/xz.tar.gz" "$url" "$sum" ;;
    esac
done <<PINS
$pins
PINS

# Dependency builds are pinned too: recipe or source changes rebuild them.
deps="$work/deps"
pinsum=$(cat "$here/pins" "$here/build.sh" | shasum -a 256 | cut -d' ' -f1)
if [ "$(cat "$deps/pins.sha" 2>/dev/null || true)" != "$pinsum" ]; then
    rm -rf "$deps"
    mkdir -p "$deps"
    echo "$pinsum" > "$deps/pins.sha"
fi

# liblzma, universal and static: innoextract needs it for the LZMA streams Inno
# uses since 5.x.
if [ ! -f "$deps/lib/liblzma.a" ]; then
    rm -rf "$work/xz-src" "$work/xz-build"
    mkdir -p "$work/xz-src"
    tar -xzf "$work/xz.tar.gz" -C "$work/xz-src" --strip-components 1
    cmake -S "$work/xz-src" -B "$work/xz-build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$minver -DCMAKE_OSX_ARCHITECTURES="$arches" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$deps" \
        -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
        -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF \
        -DXZ_DOXYGEN=OFF -DXZ_NLS=OFF \
        -DXZ_MICROLZMA_ENCODER=OFF -DXZ_MICROLZMA_DECODER=OFF -DXZ_LZIP_DECODER=OFF
    cmake --build "$work/xz-build" --parallel --target liblzma
    cmake --install "$work/xz-build"
fi

# Boost: only the components innoextract links, universal and static. zlib and
# bzip2 stay the OS's own; iostreams needs their SDK headers only to compile.
if [ ! -f "$deps/lib/libboost_iostreams.a" ]; then
    rm -rf "$work/boost-src"
    mkdir -p "$work/boost-src"
    tar -xzf "$work/boost.tar.gz" -C "$work/boost-src" --strip-components 1
    (cd "$work/boost-src" && \
        ./bootstrap.sh --prefix="$deps" \
            --with-libraries=iostreams,filesystem,date_time,system,program_options && \
        ./b2 -d0 -q --prefix="$deps" install link=static variant=release threading=multi \
            --with-iostreams --with-filesystem --with-date_time --with-system --with-program_options \
            cxxflags="-arch arm64 -arch x86_64 -mmacosx-version-min=$minver" \
            linkflags="-arch arm64 -arch x86_64" \
            -s ZLIB_INCLUDE="$sdk/usr/include" -s BZIP2_INCLUDE="$sdk/usr/include" \
            -sNO_LZMA=1 -sNO_ZSTD=1)
fi

src="$work/src"
rm -rf "$src" "$work/build"
mkdir -p "$src"
tar -xzf "$work/innoextract.tar.gz" -C "$src" --strip-components 1
for p in $patches; do patch -d "$src" -p1 --forward --quiet < "$p"; done
# The patch adds released Inno 6.4.0 on top of the 6.3.3 snapshot; make
# --version report the range the bundled build actually reads.
sed -i '' 's/to 6\.3\.3/to 6.4.0/' "$src/VERSION"

# USE_STATIC_LIBS=ON makes the configure look for libz.a/libbz2.a, which the
# macOS SDK does not ship (only .tbd stubs); keep those three dynamic.
cmake -S "$src" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$minver -DCMAKE_OSX_ARCHITECTURES="$arches" \
    -DUSE_STATIC_LIBS=ON -DBoost_USE_STATIC_LIBS=ON -DLZMA_USE_STATIC_LIBS=ON \
    -DZLIB_USE_STATIC_LIBS=OFF -DBZip2_USE_STATIC_LIBS=OFF -Diconv_USE_STATIC_LIBS=OFF \
    -DCMAKE_PREFIX_PATH="$deps" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DBoost_NO_SYSTEM_PATHS=ON \
    -DBOOST_ROOT="$deps" -DLZMA_LIBRARY="$deps/lib/liblzma.a" -DLZMA_INCLUDE_DIR="$deps/include"
cmake --build "$work/build" --parallel

mkdir -p "$(dirname "$out")"
cp "$work/build/innoextract" "$out"
# Only system libraries may remain, or the app would need Homebrew at run time.
# (A fat binary's otool -L repeats a "(architecture ...)" header line per slice,
# so keep only the indented load paths.)
if otool -L "$out" | sed -n 's|^[[:space:]]\(/[^ ]*\).*|\1|p' | grep -v -E '^/(usr/lib|System)/' | grep -q .; then
    echo "innoextract: $out links a non-system library:" >&2
    otool -L "$out" >&2
    exit 1
fi
"$out" --version | head -1
