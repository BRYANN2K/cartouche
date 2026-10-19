#!/bin/sh
# Records every exec on the Mac with eslogger while installer-inspect analyses a
# folder, then fails if any process was started from inside that folder.
# Needs root, and Full Disk Access for the terminal (eslogger requirements).
# Usage: sudo sh installer/scripts/no-exec-check.sh <folder> [installer-inspect]
set -eu

folder=$(cd "$1" && pwd -P)
inspect=${2:-installer/.build/release/installer-inspect}
log=$(mktemp -t cartouche-no-exec)

eslogger exec > "$log" &
logger=$!
sleep 2
"$inspect" "$folder" --verify
sleep 2
kill "$logger"
wait "$logger" 2>/dev/null || true

python3 -I - "$log" "$folder" <<'EOF'
import json, sys
log, folder = sys.argv[1], sys.argv[2]
started, inside = [], []
for line in open(log, encoding="utf-8", errors="replace"):
    try:
        event = json.loads(line)["event"]["exec"]
    except (ValueError, KeyError, TypeError):
        continue
    paths = [event.get("target", {}).get("executable", {}).get("path", "")]
    paths.append((event.get("script") or {}).get("path", ""))
    started.append(paths[0])
    inside += [p for p in paths if p and p.startswith(folder + "/")]
tools = sum(p.endswith("/innoextract") for p in started)
print(f"{len(started)} exec events on the Mac, {tools} of innoextract")
if inside:
    print("Started from the folder:")
    for p in inside:
        print("  " + p)
    sys.exit(1)
print(f"Nothing was started from {folder}")
EOF
echo "Raw capture: $log"
