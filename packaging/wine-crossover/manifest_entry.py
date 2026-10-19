#!/usr/bin/env python3
"""Prints the runner manifest entry for one built archive.

The entry goes into app/Sources/NotProtonApp/Resources/runners.json, whose
format RunnerManifest.swift reads. Size and SHA-256 come from the file itself.
"""
import argparse
import hashlib
import json
import pathlib
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def entry(archive, *, id, url, root, name, version, display_version, origin, loader="bin/wine"):
    path = pathlib.Path(archive)
    if not url.startswith("https://"):
        raise SystemExit(f"manifest-entry: {url} is not an https URL")
    if not url.endswith("/" + path.name):
        raise SystemExit(f"manifest-entry: {url} does not end in the archive name {path.name}")
    return {
        "id": id,
        "kind": "wineBuild",
        "origin": origin,
        "name": name,
        "version": version,
        "displayVersion": display_version,
        "url": url,
        "size": path.stat().st_size,
        "sha256": sha256(path),
        "root": root,
        "loader": loader,
        "flavors": ["rosetta"],
    }


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("archive")
    p.add_argument("--id", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--name", default="Wine CrossOver")
    p.add_argument("--version", required=True)
    p.add_argument("--display-version", required=True)
    p.add_argument("--origin", default="cartouche", choices=["cartouche", "winehq"])
    a = p.parse_args(argv)
    json.dump(entry(a.archive, id=a.id, url=a.url, root=a.root, name=a.name, version=a.version,
                    display_version=a.display_version, origin=a.origin), sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
