#!/usr/bin/env python3
"""Checks runners.json before it is published next to the compatibility data.

    runner_manifest.py check <runners.json> [--published <previous runners.json>]

The app applies the same rules (RunnerManifest.swift) and ignores a copy that
breaks them, so this only stops a bad copy earlier. A published copy must have
a higher revision than the previous one and keep the pin of every build both list.
"""
import argparse
import json
import re
import sys
from urllib.parse import urlparse

SHA256 = re.compile(r"^[0-9a-f]{64}$")
ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")


def problems(doc, previous=None):
    found = []
    if doc.get("format") != 1:
        found.append(f"format {doc.get('format')} is not 1")
    if not isinstance(doc.get("revision"), int):
        found.append("revision is not a number")
    seen = set()
    for b in doc.get("builds", []):
        at = f"build {b.get('id')}"
        if b.get("id") in seen:
            found.append(f"{at} is listed twice")
        seen.add(b.get("id"))
        if not ID.match(str(b.get("id", ""))):
            found.append(f"{at}: bad id")
        if b.get("kind") != "wineBuild":
            found.append(f"{at}: kind {b.get('kind')} is not downloadable")
        url = urlparse(str(b.get("url", "")))
        if url.scheme != "https" or url.hostname != "github.com":
            found.append(f"{at}: {b.get('url')} is not an https URL on github.com")
        if not isinstance(b.get("size"), int) or b["size"] <= 0:
            found.append(f"{at}: size {b.get('size')}")
        if not SHA256.match(str(b.get("sha256", ""))):
            found.append(f"{at}: {b.get('sha256')} is not a SHA-256")
        for key in ("root", "loader"):
            path = str(b.get(key, ""))
            if not path or path.startswith("/") or ".." in path.split("/"):
                found.append(f"{at}: {key} {path} leaves the runner folder")
        if not b.get("flavors") or any(f not in ("rosetta", "fex") for f in b["flavors"]):
            found.append(f"{at}: flavors {b.get('flavors')}")
    if previous is not None:
        if isinstance(doc.get("revision"), int) and doc["revision"] <= previous.get("revision", 0):
            found.append(f"revision {doc['revision']} is not above the published {previous.get('revision')}")
        before = {b["id"]: b for b in previous.get("builds", [])}
        for b in doc.get("builds", []):
            if b.get("id") in before and before[b["id"]] != b:
                found.append(f"build {b['id']} changes its published pin")
    return found


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=["check"])
    p.add_argument("manifest")
    p.add_argument("--published")
    a = p.parse_args(argv)
    with open(a.manifest) as f:
        doc = json.load(f)
    previous = None
    if a.published:
        with open(a.published) as f:
            previous = json.load(f)
    found = problems(doc, previous)
    if found:
        print("runner-manifest:", *found, sep="\n    ", file=sys.stderr)
        return 1
    print(f"==> runner-manifest: revision {doc['revision']}, {len(doc['builds'])} builds, valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
