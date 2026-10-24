#!/usr/bin/env python3
"""Checks the pins of the store clients the app downloads (store-clients.json).

    store_clients.py check  <store-clients.json>
    store_clients.py verify <store-clients.json> [--download <folder>]

check applies the rules the app applies (StoreClientManifest.swift) without the
network. verify asks GitHub for each pinned release: the asset must exist with
the pinned size and the SHA-256 GitHub computed when it was uploaded, and the
repository's license must be the pinned one. With --download it also fetches
each file and hashes it. Set GH_TOKEN or GITHUB_TOKEN to avoid the API's limit.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
from urllib.parse import urlparse

SHA256 = re.compile(r"^[0-9a-f]{64}$")
CLIENTS = ("legendary", "gogdl", "comet", "nile")
# Licenses that let Cartouche download the client for the user and run it
LICENSES = ("GPL-3.0", "Apache-2.0", "MIT")


def problems(doc):
    found = []
    if doc.get("format") != 1:
        found.append(f"format {doc.get('format')} is not 1")
    if not isinstance(doc.get("revision"), int):
        found.append("revision is not a number")
    pins = doc.get("clients", [])
    names = [p.get("client") for p in pins]
    for name in CLIENTS:
        if name not in names:
            found.append(f"{name} is not pinned")
    seen = set()
    for p in pins:
        at = f"client {p.get('client')}"
        if p.get("client") in seen:
            found.append(f"{at} is listed twice")
        seen.add(p.get("client"))
        if p.get("client") not in CLIENTS:
            found.append(f"{at} is not a store client")
        for key in ("url", "source"):
            url = urlparse(str(p.get(key, "")))
            if url.scheme != "https" or url.hostname != "github.com":
                found.append(f"{at}: {p.get(key)} is not an https URL on github.com")
        if not str(p.get("url", "")).startswith(str(p.get("source", "")) + "/releases/download/"):
            found.append(f"{at}: {p.get('url')} is not a release of {p.get('source')}")
        if not isinstance(p.get("size"), int) or p["size"] <= 0:
            found.append(f"{at}: size {p.get('size')}")
        if not SHA256.match(str(p.get("sha256", ""))):
            found.append(f"{at}: {p.get('sha256')} is not a SHA-256")
        if p.get("license") not in LICENSES:
            found.append(f"{at}: license {p.get('license')} is not allowed")
    return found


def release_of(pin):
    # https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
    parts = urlparse(pin["url"]).path.strip("/").split("/")
    return parts[0] + "/" + parts[1], parts[4], parts[5]


def api(path):
    request = urllib.request.Request(f"https://api.github.com/{path}",
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "cartouche-store-clients"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def remote_problems(doc, fetch=api):
    found = []
    for p in doc.get("clients", []):
        at = f"client {p['client']}"
        repo, tag, name = release_of(p)
        release = fetch(f"repos/{repo}/releases/tags/{tag}")
        asset = next((a for a in release.get("assets", []) if a.get("name") == name), None)
        if asset is None:
            found.append(f"{at}: {name} is not an asset of {repo} {tag}")
            continue
        if asset.get("size") != p["size"]:
            found.append(f"{at}: GitHub has {asset.get('size')} bytes, the pin {p['size']}")
        if asset.get("digest") != f"sha256:{p['sha256']}":
            found.append(f"{at}: GitHub has {asset.get('digest')}, the pin sha256:{p['sha256']}")
        license = (fetch(f"repos/{repo}").get("license") or {}).get("spdx_id")
        if license != p["license"]:
            found.append(f"{at}: {repo} is {license}, the pin says {p['license']}")
    return found


def download_problems(doc, folder):
    found = []
    os.makedirs(folder, exist_ok=True)
    for p in doc.get("clients", []):
        target = os.path.join(folder, os.path.basename(urlparse(p["url"]).path))
        urllib.request.urlretrieve(p["url"], target)
        digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
        if digest != p["sha256"] or os.path.getsize(target) != p["size"]:
            found.append(f"client {p['client']}: downloaded {digest}, {os.path.getsize(target)} bytes")
    return found


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check", "verify"])
    parser.add_argument("manifest")
    parser.add_argument("--download")
    args = parser.parse_args(argv)
    with open(args.manifest) as f:
        doc = json.load(f)
    found = problems(doc)
    if not found and args.command == "verify":
        found = remote_problems(doc)
        if not found and args.download:
            found = download_problems(doc, args.download)
    if found:
        print("store-clients:", *found, sep="\n    ", file=sys.stderr)
        return 1
    print(f"==> store-clients: revision {doc['revision']}, {len(doc['clients'])} clients, "
          + ("valid" if args.command == "check" else "match their GitHub releases"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
