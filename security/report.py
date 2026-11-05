#!/usr/bin/env python3
# Turns results.tsv into the release report section
import os, subprocess, sys

out = sys.argv[1]
rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(out, "results.tsv")) if l.strip()]
icon = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌", "INFO": "ℹ️", "SKIP": "⏭️"}

def version(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip().splitlines()[0]
    except Exception:
        return "missing"

tools = {
    "gitleaks": ["gitleaks", "version"], "osv-scanner": ["osv-scanner", "--version"], "syft": ["syft", "version"],
    "zizmor": ["zizmor", "--version"], "actionlint": ["actionlint", "-version"], "semgrep": ["semgrep", "--version"],
    "cppcheck": ["cppcheck", "--version"], "swift": ["swift", "--version"],
}
env = os.environ
print(f"# Release gate: {env.get('VERSION', '?')}\n")
print(f"Commit `{subprocess.run(['git', '-C', env['REPO'], 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()}`, changes since `{env.get('SINCE')}`.\n")
counts = {s: sum(1 for r in rows if r[0] == s) for s in icon}
print(" · ".join(f"{icon[s]} {counts[s]} {s}" for s in icon if counts[s]), "\n")
print("| | Check | Item | Detail |\n|---|---|---|---|")
for r in rows:
    r += [""] * (4 - len(r))
    print(f"| {icon.get(r[0], r[0])} | {r[1]} | {r[2]} | {r[3].replace('|', '/')} |")
print("\n## Tool versions\n")
for name, cmd in tools.items():
    print(f"- {name}: {version(cmd)}")
