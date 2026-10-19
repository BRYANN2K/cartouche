#!/bin/sh
# Fails when git tracks a RetroArch binary or a libretro core, in the
# repository or its submodules. RetroArch is built by CI and cores are
# downloaded per console, so neither belongs in git.
# usage: scan-binaries.sh <repository>
set -eu

repo=${1:?repository}
list=$(mktemp)
trap 'rm -f "$list"' EXIT

git -C "$repo" ls-files -z --recurse-submodules > "$list"
total=$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')

found=0
report() {
    echo "scan-binaries: $1: $2" >&2
    found=1
}

# By name: a core keeps its buildbot name, RetroArch its bundle name
while IFS= read -r path; do
    [ -n "$path" ] || continue
    report "$path" "named like RetroArch or a libretro core"
done <<EOF
$(tr '\0' '\n' < "$list" | grep -iE '(_libretro\.(dylib|so|dll)(\.zip)?$)|(^|/)RetroArch\.app/|(^|/)retroarch$' || true)
EOF

# By content, whatever the name: every libretro core exports retro_api_version,
# and RetroArch itself carries its frontend banner
machos=$(cd "$repo" && xargs -0 file --no-pad -F '|' < "$list" 2>/dev/null |
    grep -F '| Mach-O' | cut -d'|' -f1 || true)
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if grep -aqE 'retro_api_version|retro_load_game' "$repo/$path"; then
        report "$path" "a Mach-O with the libretro core interface"
    elif grep -aqF 'Frontend for libretro' "$repo/$path"; then
        report "$path" "a Mach-O of RetroArch"
    fi
done <<EOF
$machos
EOF

if [ "$found" -ne 0 ]; then
    echo "scan-binaries: remove these from git; CI builds RetroArch and cores are downloaded" >&2
    exit 1
fi
count=$(printf '%s\n' "$machos" | grep -c . || true)
echo "==> scan-binaries: $total tracked files, $count Mach-O, none is RetroArch or a libretro core"
