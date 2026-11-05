#!/usr/bin/env python3
"""Release helpers for the local release run on the maintainer's Mac (docs/RELEASE.md).

  meta TAG              print version, channel and flags for a tag (GITHUB_OUTPUT lines)
  bundle-version VER    print the CFBundleVersion Sparkle compares for a version
  notes VERSION         print the CHANGELOG section of a version
  previous-archives     print "version url" of the newest items in an appcast
  merge-appcast         keep the new item from generate_appcast, every other item as published
  announce              add an informational item (no archive) on the stable channel
  notes-url VERSION     print the site page the update window shows for a version
  site-entry VERSION    print a site changelog entry made from the CHANGELOG section
  fetch-notes VERSION   download that page, refusing anything but a 200 for this version
  link-notes            point the new item at the page, signed; the embedded notes stay
  unlink-notes          drop every page link, so Sparkle shows the embedded notes again
  notes-link-of         print "url signature length" of an item's page link
  checksums FILE...     write SHA256SUMS for the given files
  cask                  fill the Homebrew cask template

Tags: vX.Y.Z is a release, vX.Y.Z-betaN (or -beta.N, the same number) a beta
(Sparkle channel "beta"), and vX.Y.Z-test.N a pipeline test, allowed only before
the first release.

Sparkle reads "0.2.0-beta1" as equal to "0.2.0" and to "0.2.0-beta2", so the
bundle version of a pre-release drops the dash: 0.2.0b1, 0.0.1t1. Sparkle then
orders 0.1.0 < 0.2.0b1 < 0.2.0b2 < 0.2.0. The Makefile applies the same rule.
"""
import argparse
import datetime
import email.utils
import hashlib
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = "{%s}" % SPARKLE_NS
# beta takes its number with or without a dot (beta1, beta.1), test only with one
VERSION_RE = r"(\d+\.\d+\.\d+)(?:-(beta|test)(?:(?<=beta)\.?|(?<=test)\.)(\d+))?"
TAG_RE = re.compile(rf"^v{VERSION_RE}$")
ARCHIVE = "Cartouche-{version}.zip"
SITE = "https://cartouche.bryann2k.dev"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


class ReleaseError(Exception):
    pass


def parse_tag(tag):
    m = TAG_RE.match(tag)
    if not m:
        raise ReleaseError(f"{tag} is not vX.Y.Z, vX.Y.Z-betaN or vX.Y.Z-test.N")
    version = tag[1:]
    kind = m.group(2) or "release"
    return version, kind


def bundle_version(version):
    m = re.fullmatch(VERSION_RE, version)
    if not m:
        raise ReleaseError(f"{version} is not X.Y.Z, X.Y.Z-betaN or X.Y.Z-test.N")
    if not m.group(2):
        return version
    return f"{m.group(1)}{m.group(2)[0]}{m.group(3)}"


def version_key(version):
    """Sort key in semver order: 0.1.0 < 0.2.0-beta1 < 0.2.0-beta.2 < 0.2.0-beta10 < 0.2.0.
    beta1 and beta.1 are the same. The app's CartoucheVersion orders the same way
    (packaging/tests/version-order.txt)."""
    core, _, pre = version.split("+", 1)[0].partition("-")
    nums = [int(p) for p in core.split(".")]
    while len(nums) > 1 and nums[-1] == 0:
        nums.pop()
    # A release sorts after all its pre-releases; numeric identifiers before words
    pre = re.sub(r"^beta(\d+)", r"beta.\1", pre)
    ids = tuple((0, int(i), "") if i.isdigit() else (1, 0, i) for i in pre.split(".")) if pre else ()
    return (tuple(nums), 0 if pre else 1, ids)


def header_version(path):
    m = re.search(r'#define CARTOUCHE_VERSION "([^"]+)"', pathlib.Path(path).read_text())
    if not m:
        raise ReleaseError(f"no CARTOUCHE_VERSION in {path}")
    return m.group(1)


def changelog_section(changelog, version):
    """Body and heading of '## [version]', the heading may end in '(critical)'."""
    text = pathlib.Path(changelog).read_text()
    heading = re.compile(r"^## \[(?P<v>[^\]]+)\](?P<rest>.*)$", re.M)
    matches = list(heading.finditer(text))
    for i, m in enumerate(matches):
        if m.group("v") != version:
            continue
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[m.end():end].strip()
        if not body:
            raise ReleaseError(f"the CHANGELOG section for {version} is empty")
        return body, m.group("rest")
    raise ReleaseError(f"CHANGELOG has no '## [{version}]' section")


def meta(tag, header, changelog, published_releases):
    version, kind = parse_tag(tag)
    built = header_version(header)
    if built != version:
        raise ReleaseError(f"tag {tag} but {header} says {built}; bump CARTOUCHE_VERSION first")
    released = [parse_tag(t)[0] for t in published_releases if TAG_RE.match(t) and parse_tag(t)[1] == "release"]
    if kind == "test" and released:
        raise ReleaseError("test tags are for the pipeline before the first release; one is published")
    newest = max(released, key=version_key, default=None)
    if newest and version_key(version) <= version_key(newest):
        raise ReleaseError(f"{version} is not newer than the published release {newest}")
    _, rest = changelog_section(changelog, version)
    critical = "(critical)" in rest
    return {
        "version": version,
        "bundle_version": bundle_version(version),
        "kind": kind,
        "channel": "beta" if kind == "beta" else "",
        "prerelease": "true" if kind == "beta" else "false",
        "critical": "true" if critical else "false",
        "archive": ARCHIVE.format(version=version),
        # A beta must not take over releases/latest, where the appcast and the cask point
        "bump_tap": "true" if kind == "release" else "false",
    }


def items(root):
    channel = root.find("channel")
    if channel is None:
        raise ReleaseError("appcast has no <channel>")
    return channel, channel.findall("item")


def item_version(item):
    v = item.find(S + "version")
    if v is None or not (v.text or "").strip():
        raise ReleaseError("appcast item without sparkle:version")
    return v.text.strip()


def previous_archives(appcast, count):
    _, its = items(ET.parse(appcast).getroot())
    out = []
    for item in its[:count]:
        enc = item.find("enclosure")
        if enc is not None and enc.get("url"):
            out.append((item_version(item), enc.get("url")))
    return out


def is_test(bundle_version):
    return re.search(r"\dt\d+$", bundle_version) is not None


def merge_appcast(previous, generated, version, archive, url_prefix):
    """The feed to publish: the new item as generate_appcast wrote it, then every
    other item exactly as it was published.

    generate_appcast points every item it sees at the new release's download
    folder, but older archives stay in their own release, so only the new item
    can come from it. version is the bundle version. Returns the tree and the
    delta file names to upload."""
    gen_root = ET.parse(generated).getroot()
    _, gen_items = items(gen_root)
    new = [i for i in gen_items if item_version(i) == version]
    if len(new) != 1:
        raise ReleaseError(f"generate_appcast wrote {len(new)} items for {version}")
    new = new[0]

    enc = new.find("enclosure")
    if enc is None or not enc.get(S + "edSignature"):
        raise ReleaseError(f"the {version} archive has no EdDSA signature; is SUPublicEDKey in the app?")
    expected = url_prefix + archive
    if enc.get("url") != expected:
        raise ReleaseError(f"the {version} archive points at {enc.get('url')}, expected {expected}")
    deltas = []
    for d in new.findall(f"{S}deltas/enclosure"):
        url = d.get("url", "")
        if not d.get(S + "edSignature"):
            raise ReleaseError(f"delta {url} has no EdDSA signature")
        if not url.startswith(url_prefix):
            raise ReleaseError(f"delta {url} is not under {url_prefix}")
        deltas.append(url[len(url_prefix):])

    channel, _ = items(gen_root)
    for i in list(channel.findall("item")):
        channel.remove(i)
    channel.append(new)
    if previous is not None:
        _, old_items = items(ET.parse(previous).getroot())
        for item in old_items:
            v = item_version(item)
            # Test items go when the first real version is published
            if v == version or (is_test(v) and not is_test(version)):
                continue
            channel.append(item)
    return gen_root, deltas


ANNOUNCE_VERSION_RE = re.compile(r"\d+(\.\d+){1,3}$")


def announce(root, version, link, notes, title=None, display=None, date=None):
    """An informational item on the stable channel: no archive, so Sparkle shows
    "Learn More…" and opens link in the browser. version is the bundle version
    the item carries; pick one no real version will ever equal (0.1.2.1 after
    0.1.2) so 'Skip This Version' hides nothing real. Refuses a version an
    existing stable item already covers, which would never be offered."""
    if not ANNOUNCE_VERSION_RE.fullmatch(version or ""):
        raise ReleaseError(f"{version} is not a version like 0.1.2.1")
    if not (notes or "").strip():
        raise ReleaseError("the announcement notes are empty")
    parts = urllib.parse.urlsplit(link or "")
    local = parts.hostname in ("127.0.0.1", "localhost")
    if parts.scheme != "https" and not (parts.scheme == "http" and local):
        raise ReleaseError(f"{link} is not https")
    channel, its = items(root)
    wanted = tuple(int(p) for p in version.split("."))
    for item in its:
        old = item_version(item)
        if old == version:
            raise ReleaseError(f"{version} is already an item in the feed")
        if item.find(S + "channel") is not None:
            continue
        try:
            have = tuple(int(p) for p in old.split("."))
        except ValueError:
            continue
        if have >= wanted:
            raise ReleaseError(f"{version} would never be offered: {old} is already on the stable channel")
    item = ET.Element("item")
    ET.SubElement(item, "title").text = title or f"Cartouche {display or version}"
    ET.SubElement(item, "link").text = link
    ET.SubElement(item, S + "version").text = version
    if display:
        ET.SubElement(item, S + "shortVersionString").text = display
    ET.SubElement(item, S + "informationalUpdate")
    ET.SubElement(item, "pubDate").text = date or email.utils.format_datetime(
        datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, "description").text = notes.strip()
    first = channel.find("item")
    channel.insert(list(channel).index(first) if first is not None else len(list(channel)), item)
    return root


def notes_url(version, site=SITE):
    bundle_version(version)
    return f"{site.rstrip('/')}/changelog/{version}/sparkle"


def site_entry(changelog, version, title):
    text = pathlib.Path(changelog).read_text()
    m = re.search(r"^## \[" + re.escape(version) + r"\](.*)$", text, re.M)
    body, rest = changelog_section(changelog, version)
    date = re.search(r"\d{4}-\d{2}-\d{2}", m.group(1) if m else "")
    if not date:
        raise ReleaseError(f"the CHANGELOG heading of {version} has no date")
    critical = "critical: true\n" if "(critical)" in rest else ""
    title = title.replace('"', "'")
    return f'---\nversion: "{version}"\ndate: {date.group(0)}\ntitle: "{title}"\n{critical}---\n\n{body}\n'


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ReleaseError(f"{req.full_url} redirects to {newurl}; the appcast must name the final URL")


def fetch_notes(url, version, opener=None):
    """The page bytes Sparkle will download, after checking they are this version's page."""
    parts = urllib.parse.urlsplit(url)
    local = parts.hostname in ("127.0.0.1", "localhost")
    if parts.scheme != "https" and not (parts.scheme == "http" and local):
        raise ReleaseError(f"{url} is not https")
    opener = opener or urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "Cartouche-release", "Cache-Control": "no-cache"})
    try:
        with opener.open(req, timeout=20) as r:
            status, ctype, data = r.status, r.headers.get("Content-Type", ""), r.read()
    except urllib.error.HTTPError as e:
        e.close()
        raise ReleaseError(f"{url} answered {e.code}; deploy the site entry for {version} first")
    except urllib.error.URLError as e:
        raise ReleaseError(f"{url} is unreachable: {e.reason}")
    if status != 200:
        raise ReleaseError(f"{url} answered {status}, not 200")
    if not ctype.startswith("text/html"):
        raise ReleaseError(f"{url} is {ctype or 'untyped'}, not text/html")
    if f'<meta name="cartouche-version" content="{version}">'.encode() not in data:
        raise ReleaseError(f"{url} is not the Sparkle page of {version}")
    if b"<script" in data.lower():
        raise ReleaseError(f"{url} carries a script; the Sparkle page must not")
    return data


def _item(root, version):
    _, its = items(root)
    found = [i for i in its if item_version(i) == version]
    if len(found) != 1:
        raise ReleaseError(f"the appcast has {len(found)} items for {version}")
    return found[0]


def link_notes(root, version, url, signature, length, full_url=None):
    """Sparkle shows the linked page and ignores <description> while the link is
    there; the description stays as the fallback unlink_notes brings back."""
    item = _item(root, version)
    if not (item.findtext("description") or "").strip():
        raise ReleaseError(f"the {version} item has no embedded notes to fall back on")
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature or ""):
        raise ReleaseError(f"{signature!r} is not an EdDSA signature")
    if length <= 0:
        raise ReleaseError("the release notes page is empty")
    for tag in ("releaseNotesLink", "fullReleaseNotesLink"):
        for old in item.findall(S + tag):
            item.remove(old)
    link = ET.SubElement(item, S + "releaseNotesLink", {S + "edSignature": signature, S + "length": str(length)})
    link.text = url
    if full_url:
        ET.SubElement(item, S + "fullReleaseNotesLink").text = full_url
    return root


def unlink_notes(root):
    removed = 0
    _, its = items(root)
    for item in its:
        for old in item.findall(S + "releaseNotesLink"):
            item.remove(old)
            removed += 1
    return removed


def notes_link_of(root, version=None):
    _, its = items(root)
    item = _item(root, version) if version else (its[0] if its else None)
    link = None if item is None else item.find(S + "releaseNotesLink")
    if link is None:
        raise ReleaseError("no releaseNotesLink in that item")
    return (link.text or "").strip(), link.get(S + "edSignature", ""), int(link.get(S + "length", "0"))


def write_tree(root, out):
    ET.indent(root, space="    ")
    data = ET.tostring(root, encoding="unicode", xml_declaration=False)
    pathlib.Path(out).write_text('<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n' + data + "\n")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def checksums(files):
    # The format 'shasum -a 256 -c' and 'sha256sum -c' read
    return "".join(f"{sha256(p)}  {pathlib.Path(p).name}\n" for p in files)


def cask(template, version, digest):
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ReleaseError(f"{digest} is not a SHA-256")
    text = pathlib.Path(template).read_text()
    for key, value in (("@VERSION@", version), ("@SHA256@", digest)):
        if key not in text:
            raise ReleaseError(f"{template} has no {key}")
        text = text.replace(key, value)
    return text


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bundle-version")
    b.add_argument("version")
    m = sub.add_parser("meta")
    m.add_argument("tag")
    m.add_argument("--header", default=ROOT / "dylib/version.h")
    m.add_argument("--changelog", default=ROOT / "CHANGELOG.md")
    m.add_argument("--published", default="", help="space-separated tags already released")
    n = sub.add_parser("notes")
    n.add_argument("version")
    n.add_argument("--changelog", default=ROOT / "CHANGELOG.md")
    pa = sub.add_parser("previous-archives")
    pa.add_argument("appcast")
    pa.add_argument("--count", type=int, default=3)
    ma = sub.add_parser("merge-appcast")
    ma.add_argument("--previous", help="the published appcast, absent for the first release")
    ma.add_argument("--generated", required=True)
    ma.add_argument("--version", required=True, help="the bundle version of the new item")
    ma.add_argument("--archive", required=True, help="the new archive's file name")
    ma.add_argument("--url-prefix", required=True)
    ma.add_argument("--out", required=True)
    ma.add_argument("--deltas-out", required=True, help="file listing the delta files to upload")
    an = sub.add_parser("announce")
    an.add_argument("--appcast", required=True, help="the published feed, updated in place")
    an.add_argument("--version", required=True, help="the item's bundle version, e.g. 0.1.2.1")
    an.add_argument("--link", required=True, help="the page 'Learn More…' opens")
    an.add_argument("--notes-file", required=True, help="HTML file with the short FR/EN notes")
    an.add_argument("--title", help="default 'Cartouche <display or version>'")
    an.add_argument("--display", help="the version the alert names, e.g. '0.2.0 bêta'")
    an.add_argument("--date", help="pubDate; default now")
    nu = sub.add_parser("notes-url")
    nu.add_argument("version")
    nu.add_argument("--site", default=SITE)
    se = sub.add_parser("site-entry")
    se.add_argument("version")
    se.add_argument("--title", required=True)
    se.add_argument("--changelog", default=ROOT / "CHANGELOG.md")
    fn = sub.add_parser("fetch-notes")
    fn.add_argument("version")
    fn.add_argument("--url", required=True)
    fn.add_argument("--out", required=True)
    ln = sub.add_parser("link-notes")
    ln.add_argument("--appcast", required=True)
    ln.add_argument("--version", required=True, help="the bundle version of the item")
    ln.add_argument("--url", required=True)
    ln.add_argument("--signature", required=True)
    ln.add_argument("--notes-file", required=True, help="the page bytes that were signed")
    ln.add_argument("--full-url")
    un = sub.add_parser("unlink-notes")
    un.add_argument("--appcast", required=True)
    nl = sub.add_parser("notes-link-of")
    nl.add_argument("appcast")
    nl.add_argument("--version", help="the bundle version; default the first item")
    c = sub.add_parser("checksums")
    c.add_argument("files", nargs="+")
    c.add_argument("--out", required=True)
    k = sub.add_parser("cask")
    k.add_argument("--template", default=ROOT / "packaging/homebrew/cartouche.rb.in")
    k.add_argument("--version", required=True)
    k.add_argument("--sha256", required=True)
    k.add_argument("--out", required=True)
    a = p.parse_args(argv)

    try:
        if a.cmd == "meta":
            for key, value in meta(a.tag, a.header, a.changelog, a.published.split()).items():
                print(f"{key}={value}")
        elif a.cmd == "bundle-version":
            print(bundle_version(a.version))
        elif a.cmd == "notes":
            print(changelog_section(a.changelog, a.version)[0])
        elif a.cmd == "previous-archives":
            for version, url in previous_archives(a.appcast, a.count):
                print(version, url)
        elif a.cmd == "merge-appcast":
            root, deltas = merge_appcast(a.previous, a.generated, a.version, a.archive, a.url_prefix)
            write_tree(root, a.out)
            pathlib.Path(a.deltas_out).write_text("".join(d + "\n" for d in deltas))
        elif a.cmd == "announce":
            root = ET.parse(a.appcast).getroot()
            notes = pathlib.Path(a.notes_file).read_text()
            write_tree(announce(root, a.version, a.link, notes, a.title, a.display, a.date), a.appcast)
        elif a.cmd == "notes-url":
            print(notes_url(a.version, a.site))
        elif a.cmd == "site-entry":
            sys.stdout.write(site_entry(a.changelog, a.version, a.title))
        elif a.cmd == "fetch-notes":
            pathlib.Path(a.out).write_bytes(fetch_notes(a.url, a.version))
        elif a.cmd == "link-notes":
            root = ET.parse(a.appcast).getroot()
            length = pathlib.Path(a.notes_file).stat().st_size
            write_tree(link_notes(root, a.version, a.url, a.signature, length, a.full_url), a.appcast)
        elif a.cmd == "unlink-notes":
            root = ET.parse(a.appcast).getroot()
            print(f"{unlink_notes(root)} links removed; sign the feed again")
            write_tree(root, a.appcast)
        elif a.cmd == "notes-link-of":
            print(*notes_link_of(ET.parse(a.appcast).getroot(), a.version))
        elif a.cmd == "checksums":
            pathlib.Path(a.out).write_text(checksums(a.files))
        elif a.cmd == "cask":
            pathlib.Path(a.out).write_text(cask(a.template, a.version, a.sha256))
    except (ReleaseError, OSError, ET.ParseError) as e:
        print(f"release.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
