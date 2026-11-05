#!/bin/sh
# Builds DXMT's d3d11.dll with 0001-GetMetalTexture.patch, from the pinned v0.80 source that
# Cartouche ships, with DXMT's own CI toolchain (llvm-mingw, 3Shain's Wine 8.16 for winebuild and
# the import libraries). Everything happens in a scratch dir; the user's Wine and DXMT stay as
# they are. The result goes to $scratch/root, a clone of Cartouche's prepared DXMT Wine root with
# the patched d3d11.dll, for tests only (run.sh FRAMEGEN_ROOT=...).
# Usage: build.sh [scratch dir]   clean: rm -rf the scratch dir
set -eu
here=$(cd "$(dirname "$0")" && pwd)
scratch="${1:-$HOME/Library/Caches/cartouche-fg-dxmt}"
dxmt_tag=v0.80
dxmt_commit=589adb780354b461645b29999cefaf533594ee99
mingw=llvm-mingw-20251216-ucrt-macos-universal
mingw_sha=38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160
wine_url=https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
wine_sha=289c7f19e270a3d3d0a6fdb07691b176c70a0795f6811e5255cba82425de4f10
support="$HOME/Library/Application Support/Cartouche"
graphics="$support/runners/.graphics/${FRAMEGEN_WINE:-wine-crossover-26.3.0-2}/dxmt"

mkdir -p "$scratch/dl"
cd "$scratch"

fetch() { # url file sha
	[ -f "dl/$2" ] || { curl -fsSL -o "dl/$2.part" "$1" && mv "dl/$2.part" "dl/$2"; }
	echo "$3  dl/$2" | shasum -a 256 -c - >/dev/null || { echo "build.sh: $2 checksum mismatch" >&2; exit 1; }
}

if [ ! -d src ]; then
	git clone -q --depth 1 --branch "$dxmt_tag" https://github.com/3Shain/dxmt.git src
	git -C src -c submodule.external/nvapi.update=none submodule update -q --init --depth 1 include/native/directx
fi
[ "$(git -C src rev-parse HEAD)" = "$dxmt_commit" ] || { echo "build.sh: src is not DXMT $dxmt_tag" >&2; exit 1; }
if ! git -C src apply --reverse --check "$here/0001-GetMetalTexture.patch" 2>/dev/null; then
	git -C src apply "$here/0001-GetMetalTexture.patch"
fi

if [ ! -d "$mingw" ]; then
	fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/$mingw.tar.xz" llvm-mingw.tar.xz "$mingw_sha"
	tar -xf dl/llvm-mingw.tar.xz
fi
if [ ! -x wine/bin/winebuild ]; then
	fetch "$wine_url" wine.tar.gz "$wine_sha"
	mkdir -p wine
	tar -xzf dl/wine.tar.gz -C wine ./bin/winebuild ./lib/wine/x86_64-windows/libwinecrt0.a \
		./lib/wine/x86_64-windows/libntdll.a ./lib/wine/x86_64-windows/libdbghelp.a \
		./lib/wine/x86_64-unix/winemac.so ./lib/wine/x86_64-unix/ntdll.so
fi
if [ ! -x venv/bin/meson ]; then
	python3 -m venv venv
	venv/bin/pip install -q meson==1.10.0 ninja==1.13.2
fi
# airconv's native half needs LLVM 15, only for winemetal.so, which is not rebuilt
mkdir -p nollvm/include

export PATH="$scratch/$mingw/bin:$scratch/venv/bin:$PATH"
if [ ! -f build/build.ninja ]; then
	(cd src && meson setup --cross-file build-win64.txt -Dnative_llvm_path="$scratch/nollvm" \
		-Dwine_install_path="$scratch/wine" --buildtype release "$scratch/build" >/dev/null)
fi
ninja -j "${JOBS:-2}" -C build src/d3d11/d3d11.dll src/d3d11/d3d11.dll.postproc >/dev/null

mkdir -p install/x86_64-windows
cp build/src/d3d11/d3d11.dll install/x86_64-windows/d3d11.dll
x86_64-w64-mingw32-strip install/x86_64-windows/d3d11.dll

[ -f "$graphics/.cartouche-graphics.json" ] || { echo "build.sh: no prepared DXMT Wine at $graphics" >&2; exit 1; }
rm -rf root
cp -cR "$graphics" root
rm -f root/lib/wine/x86_64-windows/d3d11.dll
cp install/x86_64-windows/d3d11.dll root/lib/wine/x86_64-windows/d3d11.dll
echo "$scratch/root"
