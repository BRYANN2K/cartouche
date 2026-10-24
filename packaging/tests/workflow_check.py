#!/usr/bin/env python3
"""Structural check of .github/workflows, for machines without actionlint.

Checks what breaks a workflow before it runs: YAML that does not parse, jobs
without runs-on or uses, steps without run or uses, local reusable workflows
that do not accept workflow_call, needs that name no job, and shell steps that
sh -n rejects. It is not a replacement for actionlint.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("==> workflow-check: PyYAML not found, skipped")
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


def triggers(doc):
    # PyYAML reads the bare key "on" as True
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on or {}


def check(path, docs, errors):
    doc = docs[path.name]
    where = f"{path.name}"
    if not triggers(doc):
        errors.append(f"{where}: no trigger")
    jobs = doc.get("jobs") or {}
    if not jobs:
        errors.append(f"{where}: no jobs")
    for name, job in jobs.items():
        jw = f"{where} job {name}"
        if "uses" in job:
            target = job["uses"]
            if target.startswith("./.github/workflows/"):
                called = pathlib.Path(target).name
                if called not in docs:
                    errors.append(f"{jw}: calls missing {target}")
                elif "workflow_call" not in triggers(docs[called]):
                    errors.append(f"{jw}: {target} has no workflow_call trigger")
            continue
        if "runs-on" not in job:
            errors.append(f"{jw}: no runs-on")
        needs = job.get("needs", [])
        for n in [needs] if isinstance(needs, str) else needs:
            if n not in jobs:
                errors.append(f"{jw}: needs unknown job {n}")
        for i, step in enumerate(job.get("steps") or []):
            sw = f"{jw} step {step.get('name', i)}"
            if ("run" in step) == ("uses" in step):
                errors.append(f"{sw}: needs exactly one of run or uses")
            if "run" in step and step.get("shell", "bash") in ("bash", "sh"):
                # Expressions are substituted before the shell sees the script
                script = re.sub(r"\$\{\{.*?\}\}", "x", step["run"], flags=re.S)
                with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
                    f.write(script)
                    f.flush()
                    r = subprocess.run(["bash", "-n", f.name], capture_output=True, text=True)
                if r.returncode != 0:
                    errors.append(f"{sw}: shell does not parse: {r.stderr.strip()}")


def main():
    docs = {}
    errors = []
    files = sorted(WORKFLOWS.glob("*.yml"))
    for path in files:
        try:
            docs[path.name] = yaml.safe_load(path.read_text())
        except yaml.YAMLError as e:
            errors.append(f"{path.name}: {e}")
    for path in files:
        if path.name in docs:
            check(path, docs, errors)
    if errors:
        print("workflow-check:", *errors, sep="\n    ", file=sys.stderr)
        return 1
    print(f"==> workflow-check: {len(files)} workflows parse and are wired")
    return 0


if __name__ == "__main__":
    sys.exit(main())
