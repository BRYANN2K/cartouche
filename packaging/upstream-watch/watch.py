#!/usr/bin/env python3
"""Nightly upstream watch: opens one GitHub issue per upstream version that
supported.json does not list yet.

  GITHUB_TOKEN=... ./watch.py --repo BRYANN2K/NotProton [--dry-run]

Issues carry the label "upstream" and a fixed title per version, for example
"Upstream: Steam client 1792192922". An issue with that title, open or closed,
means the version was already reported, so the next night opens nothing.
Endpoints and formats: docs/research/upstream-watch-endpoints.md.
"""
import argparse
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
LABEL = "upstream"
USER_AGENT = "Cartouche-upstream-watch (+https://github.com/BRYANN2K/NotProton)"

STEAM_MANIFESTS = {
    "stable": "https://client-update.steamstatic.com/steam_client_osx",
    "beta": "https://client-update.steamstatic.com/steam_client_publicbeta_osx",
}
CROSSOVER_PAGE = "https://www.codeweavers.com/crossover/source"
APPLE_GPTK_PAGE = "https://developer.apple.com/games/game-porting-toolkit/"


class SourceError(Exception):
    pass


class Found:
    """One upstream version: the key in supported.json, the version, the issue title and link."""

    def __init__(self, key, name, version, link, note=""):
        self.key, self.version, self.link, self.note = key, version, link, note
        self.title = f"Upstream: {name} {version}"


def github_latest_release(fetch, repo):
    releases = json.loads(fetch(f"https://api.github.com/repos/{repo}/releases?per_page=10"))
    for r in releases:
        if not r.get("draft") and not r.get("prerelease"):
            return r["tag_name"], r["html_url"]
    raise SourceError(f"{repo} has no published release")


def notproton(fetch):
    tag, url = github_latest_release(fetch, "NotProtonNot/NotProton")
    return [Found("notproton", "NotProton", tag.removeprefix("v"), url)]


def steam(fetch):
    found = []
    for branch, url in STEAM_MANIFESTS.items():
        m = re.search(r'^\s*"version"\s+"(\d+)"', fetch(url), re.M)
        if not m:
            raise SourceError(f"no version in the Steam {branch} manifest")
        found.append(Found("steam", "Steam client", m.group(1), url, f"Branch: {branch}."))
    return found


def crossover(fetch):
    versions = re.findall(r"crossover-sources-(\d+(?:\.\d+)+)\.tar\.gz", fetch(CROSSOVER_PAGE))
    if not versions:
        raise SourceError("no crossover-sources tarball on the CodeWeavers source page")
    latest = max(versions, key=lambda v: tuple(int(p) for p in v.split(".")))
    tarball = f"https://media.codeweavers.com/pub/crossover/source/crossover-sources-{latest}.tar.gz"
    return [Found("crossover-source", "CrossOver source", latest, CROSSOVER_PAGE, f"Tarball: {tarball}")]


def wine(fetch):
    # WineHQ's own macOS folder is stale; these are the builds its macOS page points to
    tag, url = github_latest_release(fetch, "Gcenx/macOS_Wine_builds")
    return [Found("wine-macos", "Wine macOS build", tag, url)]


def dxmt(fetch):
    tag, url = github_latest_release(fetch, "3Shain/dxmt")
    return [Found("dxmt", "DXMT", tag.removeprefix("v"), url)]


def gptk(fetch):
    # Apple announces a major on its page before a build exists; Gcenx packages the builds
    found = []
    m = re.search(r"Game Porting Toolkit (\d+)", fetch(APPLE_GPTK_PAGE))
    if not m:
        raise SourceError("no version on Apple's Game Porting Toolkit page")
    found.append(Found("gptk-apple", "Game Porting Toolkit", m.group(1), APPLE_GPTK_PAGE,
                       "Announced on Apple's page. Cartouche never redistributes it."))
    tag, url = github_latest_release(fetch, "Gcenx/game-porting-toolkit")
    found.append(Found("gptk", "Game Porting Toolkit", tag.removeprefix("Game-Porting-Toolkit-"), url,
                       "Build packaged by Gcenx. Cartouche never redistributes it."))
    return found


SOURCES = [notproton, steam, crossover, wine, dxmt, gptk]


def issue_body(f):
    lines = [f"A new upstream version is out: **{f.version}**.", "", f"Link: {f.link}"]
    if f.note:
        lines += ["", f.note]
    lines += ["", f"Once Cartouche supports it, add `{f.version}` under `{f.key}` in "
              "`packaging/upstream-watch/supported.json`.", "", "Opened by the nightly upstream watch."]
    return "\n".join(lines)


class GitHubIssues:
    def __init__(self, repo, token, request):
        self.repo, self.token, self.request = repo, token, request

    def call(self, method, path, body=None):
        return self.request(method, f"https://api.github.com/repos/{self.repo}{path}", body, self.token)

    def titles(self):
        titles, page = set(), 1
        while True:
            batch = self.call("GET", f"/issues?state=all&labels={LABEL}&per_page=100&page={page}")
            titles.update(i["title"] for i in batch)
            if len(batch) < 100:
                return titles
            page += 1

    def ensure_label(self):
        try:
            self.call("POST", "/labels", {"name": LABEL, "color": "c5def5",
                                          "description": "New version of something Cartouche depends on"})
        except urllib.error.HTTPError as e:
            if e.code != 422:  # already exists
                raise

    def create(self, title, body):
        return self.call("POST", "/issues", {"title": title, "body": body, "labels": [LABEL]})["html_url"]


def http_request(method, url, body=None, token=None):
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def http_fetch(url, token=None):
    headers = {"User-Agent": USER_AGENT}
    if token and urllib.parse.urlparse(url).hostname == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def run(fetch, issues, supported, dry_run=False, out=print):
    """Returns (opened titles, failed source names)."""
    known = issues.titles()
    opened, failed = [], []
    if not dry_run:
        issues.ensure_label()
    for source in SOURCES:
        try:
            found = source(fetch)
        except (SourceError, OSError, ValueError, KeyError) as e:
            out(f"upstream-watch: {source.__name__} failed: {e}")
            failed.append(source.__name__)
            continue
        for f in found:
            if f.version in supported.get(f.key, []):
                out(f"{f.title}: supported")
            elif f.title in known:
                out(f"{f.title}: already reported")
            else:
                out(f"{f.title}: new, {'would open' if dry_run else 'opening'} an issue")
                if not dry_run:
                    out(f"    {issues.create(f.title, issue_body(f))}")
                known.add(f.title)
                opened.append(f.title)
    return opened, failed


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"), required=not os.environ.get("GITHUB_REPOSITORY"))
    p.add_argument("--supported", default=HERE / "supported.json")
    p.add_argument("--dry-run", action="store_true", help="report, open nothing")
    a = p.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN")
    supported = json.loads(pathlib.Path(a.supported).read_text())
    opened, failed = run(lambda url: http_fetch(url, token), GitHubIssues(a.repo, token, http_request),
                         supported, a.dry_run)
    print(f"==> upstream-watch: {len(opened)} new, {len(failed)} sources failed")
    # A source that changed format turns the job red, so someone looks at it
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
