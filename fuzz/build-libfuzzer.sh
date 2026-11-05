#!/bin/sh
# Builds libFuzzer.a with Xcode's clang, which ships the sanitizers but not the
# libFuzzer runtime. The sources come from a pinned LLVM commit, fetched sparse.
#
#   fuzz/build-libfuzzer.sh <out dir>
#
# LLVM_FUZZER_SRC names an existing compiler-rt/lib/fuzzer checkout to skip the fetch.
set -eu

out=$1
commit=3623fe661ae35c6c80ac221f14d85be76aa870f1 # llvmorg-21.1.0
tree=c7aa7f0f125d459d35703efada325467ce5c14b0   # compiler-rt/lib/fuzzer at that commit
flags="-arch arm64 -mmacosx-version-min=15.0 -std=c++17 -O2 -g -fno-omit-frame-pointer"
lib="$out/libFuzzer.a"
stamp="$commit $flags"
[ -f "$lib" ] && [ "$(cat "$out/STAMP" 2>/dev/null)" = "$stamp" ] && exit 0

mkdir -p "$out"
src=${LLVM_FUZZER_SRC:-}
if [ -z "$src" ]; then
  checkout="$out/llvm-project"
  if [ ! -d "$checkout/.git" ]; then
    git init -q "$checkout"
    git -C "$checkout" remote add origin https://github.com/llvm/llvm-project.git
    git -C "$checkout" config core.sparseCheckout true
    git -C "$checkout" sparse-checkout set --no-cone /compiler-rt/lib/fuzzer/
  fi
  git -C "$checkout" fetch -q --depth 1 --filter=blob:none origin "$commit"
  git -C "$checkout" checkout -q FETCH_HEAD
  # Git names objects by their content, so these two checks pin every source byte
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$commit" ] || { echo "build-libfuzzer: fetched another commit than $commit" >&2; exit 1; }
  [ "$(git -C "$checkout" rev-parse HEAD:compiler-rt/lib/fuzzer)" = "$tree" ] || { echo "build-libfuzzer: compiler-rt/lib/fuzzer is not tree $tree" >&2; exit 1; }
  git -C "$checkout" diff --quiet HEAD -- compiler-rt/lib/fuzzer || { echo "build-libfuzzer: the checkout differs from $commit" >&2; exit 1; }
  src="$checkout/compiler-rt/lib/fuzzer"
fi

objs="$out/obj"
mkdir -p "$objs"
for f in "$src"/Fuzzer*.cpp; do
  case "$f" in *Windows*|*Fuchsia*|*Linux*|*Interceptors*) continue ;; esac
  # shellcheck disable=SC2086 # flags holds several
  clang++ $flags -c "$f" -o "$objs/$(basename "$f" .cpp).o"
done
rm -f "$lib"
libtool -static -o "$lib" "$objs"/*.o
echo "$stamp" > "$out/STAMP"
echo "==> built $lib"
