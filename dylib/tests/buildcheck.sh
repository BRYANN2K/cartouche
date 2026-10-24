#!/bin/sh
# shellcheck disable=SC2034,SC2154
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "buildcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in alert_safe last_wine_build note_runner_change claim_prefix; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

np_support="$work/support"
clone() {
	inf="$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"
	mkdir -p "$(dirname "$inf")"
	: > "$inf"
	touch -t "$2" "$inf"
}
clone 26.3.0.39832 202607151200
clone 27.0.0.40921-fex 202608211200
# A downloaded Wine build: runners/<id> or the older wine-<id> shape, marked by
# an install receipt. Its wine.inf sits one level up from a clone's.
wine_clone() {
	inf="$np_support/runners/$1/share/wine/wine.inf"
	mkdir -p "$(dirname "$inf")"
	: > "$inf"
	touch -t "$3" "$inf"
	printf '{"id":"%s","archiveSHA256":"aa","files":{},"loader":"bin/wine"}\n' "$2" \
		> "$np_support/runners/$1/.cartouche-runner.json"
}
wine_clone wine-crossover-26.3.0-1 wine-crossover-26.3.0-1 202608011200
wine_clone wine-older-9.0 older-9.0 202605011200
printf 'cartouche-proton\t27.0.0.40921-fex\tfex\tCrossOver Preview (FEX)\ncartouche-proton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\ncartouche-proton-wine-crossover-26.3.0-1\twine-crossover-26.3.0-1\trosetta\tCartouche Wine 26.3\ncartouche-proton-older-9.0\tolder-9.0\trosetta\tWine 9.0\n' \
	> "$np_support/tools"
mtime() { stat -f %m "$np_support/runners/crossover-$1/CrossOver/share/wine/wine.inf"; }
wine_mtime() { stat -f %m "$np_support/runners/$1/share/wine/wine.inf"; }

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

launch() {
	build=$1 updated=$2 record=$3
	data=$(mktemp -d "$work/compatdata.XXXXXX")
	mkdir -p "$data/pfx"
	[ -z "$updated" ] || printf '%s\r\n' "$updated" > "$data/pfx/.update-timestamp"
	[ -z "$record" ] || printf '%s' "$record" > "$data/cartouche-build"
	(
		STEAM_COMPAT_DATA_PATH=$data
		np_build=$build
		np_display="display of $build"
		CX_ROOT="$np_support/runners/crossover-$build/CrossOver"
		log=/dev/null
		# shellcheck disable=SC2329 # called by the extracted refusal
		show_alert() { printf 'alert: %s\n' "$2"; }
		eval "$functions"
		note_runner_change
		claim_prefix
	) > "$data/out" 2>&1 && status=0 || status=$?
	echo "status=$status"
	grep -o 'last run by [^,]*' "$data/out" || true
	[ ! -f "$data/cartouche-build" ] || head -1 "$data/cartouche-build"
}

echo "== prefixes from before the record =="
is "a fresh prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "" "")"
is "a prefix this build last updated is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 26.3.0.39832)" "")"
is "another runner reuses the existing prefix" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921-fex)" "")"
is "an unknown previous runner reuses the existing prefix" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 1 "")"
is "updates the user disabled say nothing, so the prefix is claimed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 disable "")"

clone 27.0.0.40921 202608211200
is "ambiguous previous runners do not block a change" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(mtime 27.0.0.40921)" "")"

echo "== prefixes a downloaded build updated =="
is "a downloaded build can be changed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(wine_mtime wine-crossover-26.3.0-1)" "")"
is "the older wine- folder shape resolves through its receipt" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "$(wine_mtime wine-older-9.0)" "")"

echo "== prefixes with a record =="
is "the record wins over the Wine that updated the prefix" "status=0
27.0.0.40921-fex" "$(launch 27.0.0.40921-fex "$(mtime 26.3.0.39832)" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"
is "a recorded runner can be changed" "status=0
26.3.0.39832" "$(launch 26.3.0.39832 "" "27.0.0.40921-fex
CrossOver Preview (FEX)
")"

echo "== shared game files and saves =="
data=$(mktemp -d "$work/shared.XXXXXX")
mkdir -p "$data/pfx/drive_c/users/steamuser/Documents" "$data/game"
printf 'save data' > "$data/pfx/drive_c/users/steamuser/Documents/slot.sav"
printf 'game data' > "$data/game/Game.exe"
before=$(stat -f %i "$data/game/Game.exe")
(
    eval "$functions"
    STEAM_COMPAT_DATA_PATH=$data
    np_build=runner-a np_display=A log=/dev/null
    claim_prefix
    np_build=runner-b np_display=B
    note_runner_change
    claim_prefix
    np_build=runner-a np_display=A
    note_runner_change
    claim_prefix
)
is "game files are reused in place" "$before" "$(stat -f %i "$data/game/Game.exe")"
is "saved games survive switching back" "save data" "$(cat "$data/pfx/drive_c/users/steamuser/Documents/slot.sav")"
is "the record follows the chosen runner" "runner-a" "$(head -1 "$data/cartouche-build")"

echo "== runner root and loader =="
# The resolution blocks run top to bottom exactly as the launch does.
init=$(sed -n '/^CX_ROOT=/,/^wine_unix=/p' "$SRC")
loader=$(sed -n '/^wine_unix=/,/^export WINELOADER/p' "$SRC")
[ -n "$init" ] && [ -n "$loader" ] || { echo "FAIL: runner resolution blocks not found"; exit 1; }
resolve() {
	(
		np_build=$1
		np_flavor=$2
		eval "$init"
		eval "$loader"
		printf '%s\n%s\n' "$CX_ROOT" "$WINELOADER"
	)
}
clone_bin="$np_support/runners/crossover-26.3.0.39832/CrossOver"
mkdir -p "$clone_bin/lib/wine/x86_64-unix" "$clone_bin/bin"
: > "$clone_bin/lib/wine/x86_64-unix/wine"
chmod +x "$clone_bin/lib/wine/x86_64-unix/wine"
is "a clone keeps its own loader" "$clone_bin
$clone_bin/lib/wine/x86_64-unix/wine" "$(resolve 26.3.0.39832 rosetta)"

wine_bin="$np_support/runners/wine-crossover-26.3.0-1"
mkdir -p "$wine_bin/lib/wine/x86_64-unix" "$wine_bin/bin"
: > "$wine_bin/bin/wine"
: > "$wine_bin/lib/wine/x86_64-unix/wine"
chmod +x "$wine_bin/bin/wine" "$wine_bin/lib/wine/x86_64-unix/wine"
is "a downloaded build resolves to its folder" "$wine_bin
$wine_bin/bin/wine" "$(resolve wine-crossover-26.3.0-1 rosetta)"
printf '{"id":"wine-crossover-26.3.0-1","archiveSHA256":"aa","files":{}}\n' \
	> "$wine_bin/.cartouche-runner.json"
is "a receipt without a loader falls back to the unix loader" "$wine_bin
$wine_bin/lib/wine/x86_64-unix/wine" "$(resolve wine-crossover-26.3.0-1 rosetta)"
is "the older wine- folder shape resolves too" "$np_support/runners/wine-older-9.0
$np_support/runners/wine-older-9.0/bin/wine64" "$(
	mkdir -p "$np_support/runners/wine-older-9.0/lib/wine/x86_64-unix" \
		"$np_support/runners/wine-older-9.0/bin"
	: > "$np_support/runners/wine-older-9.0/bin/wine64"
	chmod +x "$np_support/runners/wine-older-9.0/bin/wine64"
	resolve older-9.0 rosetta)"

echo "== alerts =="
alert=$(extract show_alert)
[ -n "$alert" ] || { echo "FAIL: show_alert not found in $SRC"; exit 1; }
data=$(mktemp -d "$work/compatdata.XXXXXX")
(
	verb=waitforexitandrun
	# shellcheck disable=SC2329 # show_alert runs this in place of the real dialog
	osascript() {
		if /usr/bin/lockf -s -t 0 "$data/.cartouche-prefix.lock" true; then
			echo free > "$data/during-alert"
		else
			echo held > "$data/during-alert"
		fi
	}
	eval "$alert"
	exec 8>> "$data/.cartouche-prefix.lock"
	/usr/bin/lockf -s -t 0 8
	show_alert "title" "message"
)
is "an open alert does not keep the prefix locked" "free" "$(cat "$data/during-alert" 2>/dev/null)"

if [ "$fails" -eq 0 ]; then
	echo "==> buildcheck: all assertions hold"
else
	echo "==> buildcheck: $fails failed"
	exit 1
fi
