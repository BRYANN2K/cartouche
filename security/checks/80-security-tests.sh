#!/bin/bash
# The test suites that guard security boundaries: agent access levels and approvals, MCP transport, path containment,
# pinned downloads and signed manifests, archives, uninstall paths, Keychain
set -u
r() { printf '%s\t80-security-tests\t%s\t%s\n' "$1" "$2" "$3"; }
cd "$REPO/app" || exit 1
filter='Agent|MCP|Approval|Access|Pinned|Manifest|Signature|Archive|Extract|Uninstall|Containment|Keychain|Secret|Vault|QAEnvironment|DemoMode|StoreUninstall|Fix|Sparkle'
lock=${LOCK:-$HOME/Library/Caches/cartouche-night/locked.sh}; [ -x "$lock" ] || lock=""
$lock swift test --filter "$filter" >"$OUT/security-tests.log" 2>&1
line=$(grep -E 'Test run with [0-9]+ tests' "$OUT/security-tests.log" | tail -1)
if echo "$line" | grep -q 'passed'; then r PASS "security suites" "$line"; else r FAIL "security suites" "${line:-build failed}, security-tests.log"; fi
