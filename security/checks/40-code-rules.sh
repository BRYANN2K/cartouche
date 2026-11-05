#!/bin/bash
# Project rules (security/rules) on Swift and C: new findings since the last release fail on ERROR, warn on WARNING
set -u
r() { printf '%s\t40-code-rules\t%s\t%s\n' "$1" "$2" "$3"; }
command -v semgrep >/dev/null || { r FAIL "semgrep missing" "brew install semgrep"; exit 0; }
cd "$REPO" || exit 1
dirs=(app retroarch installer dylib fps-counter overlay-shim steam-shim helpers framegen ntdll-patch bridge)
semgrep --metrics=off --disable-version-check --config security/rules --baseline-commit "$SINCE" \
    --exclude vendor --exclude .build --exclude 'Tests' --json "${dirs[@]}" > "$OUT/semgrep.json" 2>"$OUT/semgrep.log"
python3 - "$OUT/semgrep.json" <<'PY'
import json,sys,collections
d=json.load(open(sys.argv[1]))
res=d.get("results",[])
by=collections.defaultdict(list)
for x in res: by[x["extra"]["severity"]].append(f'{x["check_id"].split(".")[-1]} {x["path"]}:{x["start"]["line"]}')
err=by.get("ERROR",[]); warn=by.get("WARNING",[])
print(("FAIL" if err else "PASS")+f"\t40-code-rules\tnew ERROR findings\t{len(err)} {' | '.join(err[:6])}")
print(("WARN" if warn else "PASS")+f"\t40-code-rules\tnew WARNING findings\t{len(warn)} {' | '.join(warn[:6])}")
scanned=len(d.get("paths",{}).get("scanned",[])); broken=len({e.get("path") for e in d.get("errors",[]) if e.get("path")})
print(f"INFO\t40-code-rules\tparser coverage\t{scanned} files scanned, {broken} not parsed (AST rules skip them; regex rules and 45-invariants still cover them)")
PY
