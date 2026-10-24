#!/bin/sh
# Accuracy and overhead of the frame counter, for each slice, with the Metal test app.
# Accuracy: a scene locked at 60 fps for ACCURACY_SECONDS (300 by default, as the spec's
# 5 minutes), averaged the way the app averages it. Overhead: the same CPU-bound bench
# RUNS times with and without the counter, in turn, BENCH_SECONDS each.
# Real games per backend are the maintainer's runs; see the P8 evidence.
# Usage: bench.sh <fps-counter.dylib> <folder with fps-present.*>
set -u
counter="$1"
bin="$2"
accuracy_seconds="${ACCURACY_SECONDS:-300}"
bench_seconds="${BENCH_SECONDS:-10}"
runs="${RUNS:-5}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

for arch in arm64 x86_64; do
  app="$bin/fps-present.$arch"
  "$app" locked 60 0 > /dev/null 2>&1 || { echo "$arch: skipped, the test app does not run here"; continue; }

  dir="$work/$arch"
  mkdir -p "$dir"
  presented=$(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" locked 60 "$accuracy_seconds")
  # The app's filter: the first 30 seconds are warm-up
  grep -v '^#' "$dir"/samples-* | sed '1d;$d' | awk -v arch="$arch" -v p="$presented" -v s="$accuracy_seconds" '
    { n++; if (n > 30) { f += $2; c++; if ($2 < lo || lo == "") lo = $2; if ($2 > hi) hi = $2 } }
    END { printf "%s accuracy: %d s locked at 60, %d s counted, average %.2f fps (min %d, max %d), %d frames presented\n", arch, s, c, f / c, lo, hi, p
          exit !(f / c >= 59 && f / c <= 61) }' || fails=$((fails + 1))

  without=""
  with=""
  # A first run warms the GPU and the caches up and is not kept; the order alternates
  "$app" bench "$bench_seconds" > /dev/null
  i=0
  while [ "$i" -lt "$runs" ]; do
    if [ $((i % 2)) -eq 0 ]; then
      without="$without $("$app" bench "$bench_seconds")"
      with="$with $(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" bench "$bench_seconds")"
    else
      with="$with $(DYLD_INSERT_LIBRARIES="$counter" CARTOUCHE_FPS_DIR="$dir" "$app" bench "$bench_seconds")"
      without="$without $("$app" bench "$bench_seconds")"
    fi
    i=$((i + 1))
  done
  printf '%s\n%s\n' "$without" "$with" | awk -v arch="$arch" -v runs="$runs" -v s="$bench_seconds" '
    NR == 1 { for (i = 1; i <= NF; i++) a += $i; a /= NF; ra = $0 }
    NR == 2 { for (i = 1; i <= NF; i++) b += $i; b /= NF; rb = $0 }
    END { d = (b - a) / a * 100; if (d < 0) m = -d; else m = d
          printf "%s overhead: %d runs of %d s, without %.2f fps (%s ), with %.2f fps (%s ), difference %+.2f%%\n", arch, runs, s, a, ra, b, rb, d
          exit !(m < 1) }' || fails=$((fails + 1))
done

[ "$fails" -eq 0 ] || { echo "==> fps counter bench: $fails result(s) outside the spec"; exit 1; }
echo "==> fps counter bench: accuracy within 60 +- 1 fps and overhead under 1%"
