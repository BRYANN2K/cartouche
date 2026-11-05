#!/bin/bash
# Cartouche release gate. Runs every check on the exact artifact that ships and writes a report.
#   security/gate.sh [--app PATH] [--since REF] [--skip ID,...] [--only ID,...] [--ci]
# --ci (or GATE_MODE=ci) runs the repository checks without an app: the parts that need the
# built app, the Swift tests or the release review are SKIP, never FAIL. Release mode is the default.
# Exit 0 only when no check fails.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$here/.." && pwd -P)
GATE_MODE=${GATE_MODE:-release}
APP=""
SINCE=""
SKIP=""
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP=$2; shift 2 ;;
        --since) SINCE=$2; shift 2 ;;
        --skip) SKIP=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --ci) GATE_MODE=ci; shift ;;
        *) echo "gate: unknown argument $1" >&2; exit 2 ;;
    esac
done
case "$GATE_MODE" in release|ci) ;; *) echo "gate: GATE_MODE must be release or ci, not $GATE_MODE" >&2; exit 2 ;; esac
# ci mode checks an app only when --app names one; a stale out/ must not stand in for it
[ -n "$APP" ] || { [ "$GATE_MODE" = ci ] && APP=/nonexistent/Cartouche.app || APP="$REPO/out/Cartouche.app"; }
if [ -z "$SINCE" ]; then
    SINCE=$(git -C "$REPO" describe --tags --abbrev=0 --match 'v0.*' 2>/dev/null || git -C "$REPO" rev-list --max-parents=0 HEAD | tail -1)
elif ! git -C "$REPO" rev-parse -q --verify "$SINCE^{commit}" >/dev/null; then
    echo "gate: --since $SINCE is not a commit here (shallow clone?)" >&2; exit 2
fi
# The artifact, the Swift security suites and the release review exist only on the release Mac
[ "$GATE_MODE" = ci ] && SKIP="60,80,90${SKIP:+,$SKIP}"
VERSION=unbuilt
[ "$GATE_MODE" = ci ] && VERSION=ci
[ -f "$APP/Contents/Info.plist" ] && VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9._-')
[ -n "$VERSION" ] || VERSION=unbuilt
OUT="$REPO/security/out/$VERSION-$(git -C "$REPO" rev-parse --short HEAD)"
rm -rf "$OUT"; mkdir -p "$OUT"
export REPO APP SINCE OUT VERSION GATE_MODE
: > "$OUT/results.tsv"
echo "==> Cartouche release gate ($GATE_MODE): $VERSION at $(git -C "$REPO" rev-parse --short HEAD), changes since $SINCE"
for check in "$here"/checks/[0-9]*.sh; do
    id=$(basename "$check" .sh)
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",${id%%-*},"*|*",$id,"*) ;; *) continue ;; esac
    fi
    case ",$SKIP," in *",${id%%-*},"*|*",$id,"*) printf 'SKIP\t%s\t%s\t%s\n' "$id" "skipped" "--skip or ci mode" >> "$OUT/results.tsv"; continue ;; esac
    start=$(date +%s)
    bash "$check" >> "$OUT/results.tsv" 2>> "$OUT/$id.stderr" \
        || printf 'FAIL\t%s\t%s\t%s\n' "$id" "check crashed" "see $id.stderr" >> "$OUT/results.tsv"
    echo "    $id ($(( $(date +%s) - start )) s)"
done
python3 "$here/report.py" "$OUT" > "$OUT/report.md"
awk -F'\t' '{print $1}' "$OUT/results.tsv" | sort | uniq -c | sed 's/^/    /'
[ "$GATE_MODE" = ci ] && grep -E '^(FAIL|WARN)' "$OUT/results.tsv" | sed 's/^/    /'
echo "==> report: $OUT/report.md"
! grep -q '^FAIL' "$OUT/results.tsv"
