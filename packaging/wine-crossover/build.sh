#!/bin/sh
# Builds Wine from CodeWeavers' CrossOver sources into an install tree laid out
# like CrossOver's own (bin/, lib/wine/<arch>-unix|windows/, share/wine/), so
# Cartouche's run script and ntdll patcher find files where they expect them.
#
#   ./build.sh <work folder>             build into <work folder>/install
#   ./build.sh --dry-run <work folder>   print the commands only
#
# Needs an x86_64 Mac with Xcode, Homebrew and the formulas in pins.env, and the
# two pinned downloads in <work folder>/downloads (fetch.sh). CI only: a full
# build takes about an hour.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
. "${PINS_FILE:-$here/pins.env}"

dry=
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
[ $# -eq 1 ] || { echo "usage: build.sh [--dry-run] <work folder>" >&2; exit 2; }
work=$1

run() {
    if [ -n "$dry" ]; then echo "+ $*"; else "$@"; fi
}

source_tar="$work/downloads/crossover-sources-$CX_VERSION.tar.gz"
mingw_tar="$work/downloads/llvm-mingw-$LLVM_MINGW_VERSION.tar.xz"
src="$work/src"
build="$work/build"
deps="$work/deps"
install="$work/install"

# Without --dry-run, refuse anything but the pinned inputs
if [ -z "$dry" ]; then
    [ "$(uname -m)" = x86_64 ] || { echo "build.sh: needs an x86_64 Mac (the runner is x86_64 code run by Rosetta)" >&2; exit 1; }
    for pin in "$source_tar:$CX_SOURCE_SHA256" "$mingw_tar:$LLVM_MINGW_SHA256"; do
        f=${pin%:*} want=${pin##*:}
        [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$want" ] || { echo "build.sh: $f does not match its pin" >&2; exit 1; }
    done
fi

[ -d "$XCODE_APP" ] && export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
export MACOSX_DEPLOYMENT_TARGET

run rm -rf "$src" "$build" "$deps" "$install" "$work/llvm-mingw"
run mkdir -p "$src" "$build" "$deps/lib" "$install" "$work/llvm-mingw"
run tar -xzf "$source_tar" -C "$src"
run tar -xJf "$mingw_tar" -C "$work/llvm-mingw" --strip-components 1
PATH="$work/llvm-mingw/bin:$PATH"

if [ -n "$dry" ]; then brew() { echo "/usr/local/opt/$2"; }; fi
for f in bison flex; do PATH="$(brew --prefix "$f")/bin:$PATH"; done
export PATH

# The dylibs Wine links or dlopens, copied with @rpath names before configure
# sees them, so the names it records are the bundled ones
lib_of() {
    case "$1" in
        freetype) echo "$(brew --prefix freetype)/lib/libfreetype.6.dylib" ;;
        gnutls) echo "$(brew --prefix gnutls)/lib/libgnutls.30.dylib" ;;
        molten-vk) echo "$(brew --prefix molten-vk)/lib/libMoltenVK.dylib" ;;
        sdl2) echo "$(brew --prefix sdl2)/lib/libSDL2-2.0.0.dylib" ;;
        *) echo "build.sh: no library known for $1" >&2; return 1 ;;
    esac
}
libs=
for f in $BREW_LINK_DEPS; do libs="$libs $(lib_of "$f")"; done
# shellcheck disable=SC2086
run sh "$here/bundle-deps.sh" "$deps/lib" $libs

# lib/wine/x86_64-unix/../../ is lib/, where the bundled dylibs go
ldflags="-L$deps/lib -Wl,-rpath,@loader_path/../../ -Wl,-headerpad_max_install_names"

cd "$build" 2>/dev/null || [ -n "$dry" ]
run "$src/sources/wine/configure" \
    --prefix="$install" \
    --enable-archs=i386,x86_64 \
    --disable-tests \
    --with-mingw \
    --with-coreaudio \
    --with-freetype \
    --with-gnutls \
    --with-opencl \
    --with-opengl \
    --with-sdl \
    --with-vulkan \
    --without-alsa --without-capi --without-dbus --without-fontconfig --without-gphoto \
    --without-gssapi --without-gstreamer --without-inotify --without-krb5 --without-netapi \
    --without-oss --without-pcap --without-pulse --without-sane --without-udev --without-usb \
    --without-v4l2 --without-wayland --without-x \
    "LDFLAGS=$ldflags" \
    "CFLAGS=-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
run make -j"$(sysctl -n hw.ncpu)"
run make install-lib
run cp -R "$deps/lib/." "$install/lib/"
run sh "$here/check-deps.sh" "$install"
[ -n "$dry" ] || "$install/bin/wine" --version
