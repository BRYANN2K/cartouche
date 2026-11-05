#!/usr/bin/env python3
"""Coverage gate for CI (docs/ci/CI.md).

Reads lcov reports, then fails when the lines a change adds or edits are covered
below --min-diff percent, or when the total line coverage falls below the
recorded baseline by more than --tolerance points. Only files under a Sources/
folder count. Lines a change touches that the compiler does not instrument
(comments, declarations) are left out of the diff figure.

  diff_coverage.py --lcov a.lcov b.lcov --base SHA [--head HEAD]
                   [--baseline tools/ci/coverage-baseline.json] [--write-baseline]
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

LISTED = 100
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def counted(path):
    return "/Sources/" in f"/{path}" and path.endswith(".swift")


def read_lcov(paths):
    """{file: {line: hits}}, the highest count when several reports share a file."""
    lines = {}
    for report in paths:
        current = None
        for raw in pathlib.Path(report).read_text().splitlines():
            if raw.startswith("SF:"):
                current = raw[3:]
                if not counted(current):
                    current = None
                    continue
                lines.setdefault(current, {})
            elif raw.startswith("DA:") and current is not None:
                number, hits = raw[3:].split(",")[:2]
                file_lines = lines[current]
                file_lines[int(number)] = max(file_lines.get(int(number), 0), int(hits))
            elif raw == "end_of_record":
                current = None
    return lines


def changed_lines(base, head):
    """{file: set of line numbers in head} for lines head adds or edits since base."""
    out = subprocess.run(
        ["git", "diff", "--unified=0", "--no-color", "--no-ext-diff", "--diff-filter=AMR", base, head, "--", "*.swift"],
        capture_output=True, text=True, check=True).stdout
    changed, current = {}, None
    for line in out.splitlines():
        if line.startswith("+++ "):
            name = line[4:]
            current = name[2:] if name.startswith("b/") else None
            if current is not None and not counted(current):
                current = None
        elif current is not None:
            m = HUNK.match(line)
            if m:
                start, count = int(m.group(1)), int(m.group(2) or 1)
                changed.setdefault(current, set()).update(range(start, start + count))
    return changed


def percent(covered, total):
    return 100.0 * covered / total if total else 100.0


def commit_exists(rev):
    return subprocess.run(["git", "cat-file", "-e", f"{rev}^{{commit}}"], capture_output=True).returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lcov", nargs="+", required=True)
    ap.add_argument("--base", default="")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--min-diff", type=float, default=80.0)
    ap.add_argument("--baseline", default="tools/ci/coverage-baseline.json")
    ap.add_argument("--tolerance", type=float, default=0.1)
    ap.add_argument("--write-baseline", action="store_true")
    args = ap.parse_args()

    lines = read_lcov(args.lcov)
    instrumented = sum(len(v) for v in lines.values())
    covered = sum(1 for v in lines.values() for hits in v.values() if hits > 0)
    total = percent(covered, instrumented)
    report = [f"total line coverage: {total:.2f}% ({covered} of {instrumented} lines, {len(lines)} files)"]
    failed = False

    if args.write_baseline:
        pathlib.Path(args.baseline).write_text(json.dumps({"total_percent": round(total, 2)}, indent=2) + "\n")
        print(f"==> diff-coverage: baseline written, {total:.2f}%")
        return 0

    baseline = json.loads(pathlib.Path(args.baseline).read_text())["total_percent"]
    if total + args.tolerance < baseline:
        failed = True
        report.append(f"FAIL total dropped below the baseline {baseline:.2f}% (tolerance {args.tolerance} points)")
    else:
        report.append(f"ok   total holds against the baseline {baseline:.2f}%")
        if total > baseline + 0.5:
            report.append(f"note total is {total - baseline:.2f} points above the baseline: "
                          f"run with --write-baseline and commit {args.baseline}")

    if not args.base or set(args.base) == {"0"} or not commit_exists(args.base):
        report.append(f"skip changed lines: no base commit to compare with ({args.base or 'none given'})")
    else:
        touched = 0
        hit = 0
        misses = []
        for path, numbers in sorted(changed_lines(args.base, args.head).items()):
            file_lines = lines.get(path, {})
            for n in sorted(numbers):
                if n not in file_lines:
                    continue
                touched += 1
                if file_lines[n] > 0:
                    hit += 1
                else:
                    misses.append((path, n))
        diff = percent(hit, touched)
        verdict = "ok  " if diff >= args.min_diff else "FAIL"
        failed |= diff < args.min_diff
        if touched:
            report.append(f"{verdict} changed lines: {diff:.2f}% covered ({hit} of {touched}), minimum {args.min_diff:.0f}%")
        else:
            report.append("ok   changed lines: none instrumented in Sources/")
        for path, n in misses[:LISTED]:
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::warning file={path},line={n}::changed line not covered by a test")
            report.append(f"     not covered: {path}:{n}")
        if len(misses) > LISTED:
            report.append(f"     and {len(misses) - LISTED} more")

    print("\n".join(report))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("## Coverage\n\n```\n" + "\n".join(report) + "\n```\n")
    print(f"==> diff-coverage: {'failed' if failed else 'passed'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
