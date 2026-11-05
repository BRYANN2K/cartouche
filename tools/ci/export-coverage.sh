#!/bin/sh
# Writes the line coverage of one Swift package's last `swift test --enable-code-coverage`
# run as lcov, with paths relative to the repository root and only the package's Sources.
# Usage: tools/ci/export-coverage.sh <package folder> <out.lcov>
set -eu
pkg="$1"
out="$2"
root=$(git rev-parse --show-toplevel)
bin=$(cd "$pkg" && swift build --show-bin-path)
profdata="$bin/codecov/default.profdata"
# swift test merges the raw profiles only when every test passed
if [ ! -f "$profdata" ] && ls "$bin"/codecov/*.profraw > /dev/null 2>&1; then
  xcrun llvm-profdata merge -sparse -o "$profdata" "$bin"/codecov/*.profraw
fi
[ -f "$profdata" ] || { echo "export-coverage: no $profdata, run swift test --enable-code-coverage in $pkg" >&2; exit 1; }
set -- "$bin"/*.xctest
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "export-coverage: want one test bundle in $bin, found: $*" >&2; exit 1; }
name=$(basename "$1" .xctest)
mkdir -p "$(dirname "$out")"
xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "$1/Contents/MacOS/$name" \
  -ignore-filename-regex '(/\.build/|/Tests/|/checkouts/)' \
  | sed "s|^SF:$root/|SF:|" > "$out"
echo "==> export-coverage: $pkg -> $out ($(grep -c '^SF:' "$out") files)"
