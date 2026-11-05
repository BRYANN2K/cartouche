#!/bin/bash
# Secrets in the commits since the last release and in the built app
set -u
r() { printf '%s\t10-secrets\t%s\t%s\n' "$1" "$2" "$3"; }
command -v gitleaks >/dev/null || { r FAIL "gitleaks missing" "brew install gitleaks"; exit 0; }
cfg=(); [ -f "$REPO/security/gitleaks.toml" ] && cfg=(--config "$REPO/security/gitleaks.toml")
if gitleaks git "$REPO" ${cfg[@]+"${cfg[@]}"} --log-opts="$SINCE..HEAD" --redact --no-banner --report-format json --report-path "$OUT/gitleaks-git.json" >"$OUT/gitleaks-git.log" 2>&1; then
    r PASS "commits since $SINCE" "no secret"
else
    r FAIL "commits since $SINCE" "$(jq length "$OUT/gitleaks-git.json" 2>/dev/null) finding(s), gitleaks-git.json"
fi
if [ -d "$APP" ]; then
    if gitleaks dir "$APP" ${cfg[@]+"${cfg[@]}"} --redact --no-banner --report-format json --report-path "$OUT/gitleaks-app.json" >"$OUT/gitleaks-app.log" 2>&1; then
        r PASS "built app" "no secret in $APP"
    else
        r FAIL "built app" "$(jq length "$OUT/gitleaks-app.json" 2>/dev/null) finding(s), gitleaks-app.json"
    fi
elif [ "${GATE_MODE:-release}" = ci ]; then
    r SKIP "built app" "ci mode: no app"
else
    r FAIL "built app" "no app at $APP (make app first)"
fi
