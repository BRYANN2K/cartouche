#!/bin/sh
# Pools several latency.sh runs: median and p95 per configuration over all their clicks, and the
# median of each run alone, to show the spread between runs.
# Usage: latency_pool.sh <LATENCY_DIR> [<LATENCY_DIR> ...]
set -u
first="$1"
printf '%-26s %5s  %6s %6s   %s\n' "configuration" "n" "median" "p95" "medians per run"
for dir in "$first"/*/; do
  name=$(basename "$dir")
  for run in "$@"; do
    [ -f "$run/$name/out" ] && awk -v run="$run" '$1 == "click" && $5 > 0 { print run, ($5 - $3) * 1000 }' "$run/$name/out"
  done | awk -v name="$name" '
    { n++; all[n] = $2; k = $1; if (!(k in seen)) { seen[k] = ++runs; order[runs] = k } c = seen[k]; m[c]++; per[c, m[c]] = $2 }
    function pct(a, n, p,   r) { r = int(p * n + 0.999999); if (r < 1) r = 1; return a[r] }
    END {
      for (i = 2; i <= n; i++) for (j = i; j > 1 && all[j - 1] > all[j]; j--) { t = all[j]; all[j] = all[j - 1]; all[j - 1] = t }
      line = ""
      for (c = 1; c <= runs; c++) {
        delete one
        for (i = 1; i <= m[c]; i++) one[i] = per[c, i]
        for (i = 2; i <= m[c]; i++) for (j = i; j > 1 && one[j - 1] > one[j]; j--) { t = one[j]; one[j] = one[j - 1]; one[j - 1] = t }
        line = line sprintf(" %.1f", pct(one, m[c], 0.5))
      }
      printf "%-26s %5d  %6.1f %6.1f  %s\n", name, n, pct(all, n, 0.5), pct(all, n, 0.95), line
    }'
done
