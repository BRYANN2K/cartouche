#!/bin/sh
# Copies dylibs and every non-system dylib they load into one folder, and makes
# them find each other through @rpath, so the package needs nothing from Homebrew.
#
#   ./bundle-deps.sh <out folder> <dylib>...
#
# Wine is then configured against this folder, so the library names it dlopens
# are @rpath names too.
set -eu

[ $# -ge 2 ] || { echo "usage: bundle-deps.sh <out folder> <dylib>..." >&2; exit 2; }
out=$1
shift
mkdir -p "$out"
out=$(cd "$out" && pwd -P)

is_system() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Dependencies of $1, one per line, without its own id
deps() {
    otool -L "$1" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' | while IFS= read -r dep; do
        [ "$dep" = "$(otool -D "$1" | tail -n +2)" ] && continue
        echo "$dep"
    done
}

# Where a dependency of $2 named $1 lives on this machine
locate() {
    dir=$(dirname "$2")
    real=$(dirname "$(realpath "$2")")
    case "$1" in
        @loader_path/*) echo "$dir/${1#@loader_path/}" ;;
        @rpath/*)
            for d in "$dir" "$real" "$out"; do
                if [ -f "$d/${1#@rpath/}" ]; then echo "$d/${1#@rpath/}"; return; fi
            done
            echo "bundle-deps: cannot find $1 needed by $2" >&2
            return 1 ;;
        *) echo "$1" ;;
    esac
}

queue=$(mktemp)
done_list=$(mktemp)
trap 'rm -f "$queue" "$done_list"' EXIT
for lib in "$@"; do echo "$lib" >> "$queue"; done

while [ -s "$queue" ]; do
    lib=$(head -n 1 "$queue")
    tail -n +2 "$queue" > "$queue.next"; mv "$queue.next" "$queue"
    leaf=$(basename "$lib")
    grep -qxF "$leaf" "$done_list" && continue
    echo "$leaf" >> "$done_list"
    [ -f "$lib" ] || { echo "bundle-deps: $lib does not exist" >&2; exit 1; }

    copy="$out/$leaf"
    cp -fL "$lib" "$copy"
    chmod u+w "$copy"
    install_name_tool -id "@rpath/$leaf" "$copy" 2>/dev/null
    for dep in $(deps "$lib"); do
        is_system "$dep" && continue
        found=$(locate "$dep" "$lib")
        install_name_tool -change "$dep" "@rpath/$(basename "$found")" "$copy" 2>/dev/null
        echo "$found" >> "$queue"
    done
    # Editing load commands breaks the signature, and arm64 refuses unsigned code
    codesign --force --sign - "$copy" 2>/dev/null
done

echo "==> bundle-deps: $(wc -l < "$done_list" | tr -d ' ') dylibs in $out"
