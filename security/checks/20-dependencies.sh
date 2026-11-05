#!/bin/bash
# Known vulnerabilities in the locked dependencies (SwiftPM, python) and in the app's SBOM
set -u
r() { printf '%s\t20-dependencies\t%s\t%s\n' "$1" "$2" "$3"; }
command -v osv-scanner >/dev/null || { r FAIL "osv-scanner missing" "brew install osv-scanner"; exit 0; }
cfg=(); [ -f "$REPO/security/osv-scanner.toml" ] && cfg=(--config "$REPO/security/osv-scanner.toml")
judge() { # $1 json, $2 title
    python3 - "$1" "$2" <<'PY'
import json,sys
p,title=sys.argv[1:3]
try: d=json.load(open(p))
except Exception as e: print(f"FAIL\t20-dependencies\t{title}\tunreadable osv output: {e}"); sys.exit()
worst=0.0; n=0; ids=[]
for res in d.get("results",[]):
    for pkg in res.get("packages",[]):
        for g in pkg.get("groups",[]):
            n+=1; ids+=g.get("ids",[])[:1]
            try: worst=max(worst,float(g.get("max_severity") or 0))
            except ValueError: worst=max(worst,7.0)
status="PASS" if n==0 else ("FAIL" if worst>=7.0 or worst==0 else "WARN")
print(f"{status}\t20-dependencies\t{title}\t{n} vulnerability group(s), worst CVSS {worst or 'unknown'} {' '.join(ids[:8])}")
PY
}
osv-scanner scan source -r "$REPO" ${cfg[@]+"${cfg[@]}"} --format json > "$OUT/osv-source.json" 2>"$OUT/osv-source.log"
judge "$OUT/osv-source.json" "lockfiles"
if [ -d "$APP" ] && command -v syft >/dev/null; then
    syft scan "dir:$APP" -o spdx-json="$OUT/sbom.spdx.json" -q 2>"$OUT/syft.log" && r PASS "SBOM" "sbom.spdx.json ($(jq '.packages|length' "$OUT/sbom.spdx.json") packages)"
    osv-scanner scan --sbom "$OUT/sbom.spdx.json" ${cfg[@]+"${cfg[@]}"} --format json > "$OUT/osv-sbom.json" 2>"$OUT/osv-sbom.log"
    judge "$OUT/osv-sbom.json" "app SBOM"
elif [ "${GATE_MODE:-release}" = ci ] && [ ! -d "$APP" ]; then
    r SKIP "SBOM" "ci mode: no app"
else
    r WARN "SBOM" "no app or no syft"
fi
