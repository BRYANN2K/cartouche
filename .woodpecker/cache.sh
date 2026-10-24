#!/bin/sh
# Persistent build cache for the Woodpecker Mac agent (local backend).
#
#   .woodpecker/cache.sh restore|save <artifact>...
#
# Each artifact is saved under $CARTOUCHE_CI_CACHE/<artifact>/ with a key file
# hashing the inputs that decide its content, the same inputs the GitHub cache
# keys used. restore clones a matching entry into the workspace with its
# mtimes (single-file outputs are touched, as the GitHub job did, so make keeps
# them); a missing or stale entry is skipped and the pipeline builds it. save
# replaces the entry from the workspace.
set -eu

CACHE="${CARTOUCHE_CI_CACHE:-$HOME/Library/Caches/woodpecker-cartouche}"
DOBBY_COMMIT="${DOBBY_COMMIT:-5dfc8546954ce3b3198132ab13fddb89ee92cdd7}"
FONT_TOOLS="${FONT_TOOLS:-afdko==4.0.3 fonttools==4.66.1}"

paths() {
	case "$1" in
	dobby) echo "build/dobby" ;;
	wine) echo "scratch/wine scratch/wine-build-dual scratch/wine-build-arm64" ;;
	proton) echo "scratch/proton-lsc" ;;
	innoextract) echo "out/innoextract" ;;
	libarchive) echo "out/libarchive.dylib" ;;
	fonts) echo "build/fonts build/fonts.stamp" ;;
	retroarch-rig) echo "build/retroarch-rig" ;;
	*) echo "unknown artifact: $1" >&2; exit 2 ;;
	esac
}

hash_files() {
	find "$@" -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1
}

key() {
	xcode="$(xcodebuild -version | tr '\n' ' ')"
	arch="$(uname -m)"
	case "$1" in
	dobby) k="$DOBBY_COMMIT" ;;
	wine) k="$(hash_files bridge/setup-wine-tree.sh bridge/register-components.diff)" ;;
	proton) k="$(hash_files lsteamclient/fetch.sh)"; xcode=any ;;
	innoextract) k="$(hash_files installer/innoextract/pins installer/innoextract/build.sh)" ;;
	libarchive) k="$(hash_files installer/libarchive/pins installer/libarchive/build.sh)" ;;
	fonts) k="$(hash_files fonts)-$FONT_TOOLS"; xcode=any ;;
	retroarch-rig) k="$(git ls-tree HEAD vendor/RetroArch | awk '{ print $3 }')-$(hash_files retroarch/scripts/build-test-rig.sh retroarch/Tests/testcore)" ;;
	esac
	printf '%s|%s|%s\n' "$k" "$xcode" "$arch"
}

restore() {
	entry="$CACHE/$1"
	if [ ! -f "$entry/key" ]; then
		echo "==> cache $1: empty, building it"
		return 0
	fi
	if [ "$(cat "$entry/key")" != "$(key "$1")" ]; then
		echo "==> cache $1: stale, building it"
		return 0
	fi
	for p in $(paths "$1"); do
		[ -e "$entry/data/$p" ] || continue
		mkdir -p "$(dirname "$p")"
		rm -rf "$p"
		cp -cpR "$entry/data/$p" "$p" 2>/dev/null || cp -pR "$entry/data/$p" "$p"
		case "$1" in innoextract | libarchive) touch "$p" ;; esac
	done
	echo "==> cache $1: restored"
}

save() {
	entry="$CACHE/$1"
	tmp="$CACHE/.$1.$$"
	rm -rf "$tmp"
	mkdir -p "$tmp/data"
	for p in $(paths "$1"); do
		[ -e "$p" ] || { echo "==> cache $1: $p missing, not saved" >&2; rm -rf "$tmp"; return 0; }
		mkdir -p "$tmp/data/$(dirname "$p")"
		cp -cpR "$p" "$tmp/data/$p" 2>/dev/null || cp -pR "$p" "$tmp/data/$p"
	done
	key "$1" > "$tmp/key"
	rm -rf "$entry"
	mv "$tmp" "$entry"
	echo "==> cache $1: saved"
}

[ $# -ge 2 ] || { echo "usage: cache.sh restore|save <artifact>..." >&2; exit 2; }
action="$1"
shift
mkdir -p "$CACHE"
for artifact in "$@"; do
	paths "$artifact" >/dev/null
	case "$action" in
	restore) restore "$artifact" ;;
	save) save "$artifact" ;;
	*) echo "usage: cache.sh restore|save <artifact>..." >&2; exit 2 ;;
	esac
done
