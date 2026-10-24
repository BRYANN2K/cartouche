"""Recorded-looking payloads for the Cartouche QA mock server.

Everything here is generated with Python's standard library only, seeded per
game, so the data looks recorded but is reproducible. Static recordings live in
data/ next to this file; the generators below fill in what was not recorded.

The eight Steam games of app/Tests/NotProtonAppTests/LibraryFixtures.swift are
the universe: 1245620 Elden Ring, 730 Counter-Strike 2, 1172470 Apex Legends,
1174180 Red Dead Redemption 2, 1593500 God of War, 1091500 Cyberpunk 2077,
1086940 Baldur's Gate 3, 367520 Hollow Knight.
"""

import datetime
import gzip
import hashlib
import io
import json
import lzma
import random
import struct
import tarfile
import zipfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
# tools/compat/fixtures holds the recorded compat build inputs
WORKTREE = HERE.parents[1]
REPO_TOOLS_COMPAT_GZ = WORKTREE / "tools" / "compat" / "fixtures" / "compat-2026-10-19.json.gz"
REPO_GPU_STRENGTH = WORKTREE / "tools" / "compat" / "gpu_strength.json"

APP_VERSION = "0.1.0"
UPDATE_VERSION = "0.2.0"
BETA_VERSION = "0.2.0-beta.1"
BETA_BUNDLE_VERSION = "0.2.0b1"

# appid, name, slug, release year
FIXTURE_GAMES = [
    (1245620, "ELDEN RING", "elden-ring", 2022),
    (730, "Counter-Strike 2", "counter-strike-2", 2023),
    (1172470, "Apex Legends", "apex-legends", 2020),
    (1174180, "Red Dead Redemption 2", "red-dead-redemption-2", 2019),
    (1593500, "God of War", "god-of-war", 2022),
    (1091500, "Cyberpunk 2077", "cyberpunk-2077", 2020),
    (1086940, "Baldur's Gate 3", "baldurs-gate-3", 2023),
    (367520, "Hollow Knight", "hollow-knight", 2017),
]

GAME_NAMES = {appid: name for appid, name, _, _ in FIXTURE_GAMES}

# /api/storesearch answers: the fixture games plus a soundtrack and a DLC, so a
# search can show that non-app results are never picked
SEARCH_ROWS = [(appid, name, "app") for appid, name, _, _ in FIXTURE_GAMES] + [
    (9995001, "ELDEN RING Soundtrack", "music"),
    (9995002, "ELDEN RING NIGHTREIGN", "dlc"),
]

# Magic appids for the edge cases every QA run needs
APPID_NO_REPORTS = 9990001   # 200, empty reviews: "No reports yet for this version"
APPID_SERVER_ERROR = 9990002  # 500: the app keeps its cache


# ---------------------------------------------------------------- images

def png(width, height, color_a, color_b=None, band=None):
    """A small real PNG (truecolor, no interlace). color_b stripes the lower
    `band` fraction when given, so box art and hero art differ visibly."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter: none
        c = color_b if color_b and band and y >= height * (1 - band) else color_a
        rows += bytes(c) * width
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )


def cover_png(appid, kind):
    rng = random.Random(0xC0FFEE ^ appid)
    base = (rng.randrange(40, 200), rng.randrange(40, 200), rng.randrange(40, 200))
    dark = tuple(c // 3 for c in base)
    if kind == "library_600x900":
        return png(120, 180, base, dark, band=0.28)
    if kind == "library_hero":
        return png(240, 100, base, dark, band=0.35)
    if kind == "library_capsule":
        return png(160, 90, base, dark, band=0.3)
    return png(120, 90, base, dark, band=0.3)


def thumbnail_png(system, kind, name):
    rng = random.Random(zlib.crc32((system + name + kind).encode()))
    base = (rng.randrange(30, 210), rng.randrange(30, 210), rng.randrange(30, 210))
    dark = tuple(c // 3 for c in base)
    if kind == "Named_Boxarts":
        return png(120, 160, base, dark, band=0.22)
    if kind == "Named_Titles":
        return png(160, 120, dark, base, band=0.15)
    return png(160, 120, base, dark, band=0.4)  # Named_Snaps


# ---------------------------------------------------------------- MacGamingDB

_CHIPS = [("M1", "BASE"), ("M1", "PRO"), ("M1", "MAX"), ("M2", "BASE"), ("M2", "PRO"),
          ("M2", "MAX"), ("M3", "BASE"), ("M3", "PRO"), ("M3", "MAX"), ("M4", "BASE"),
          ("M4", "PRO"), ("M4", "MAX"), ("M5", "BASE")]
_METHODS = ["CROSSOVER"] * 12 + ["PARALLELS"] * 3 + ["NATIVE"] * 2 + ["OTHER"]
_LAYERS = ["D3D_METAL"] * 9 + ["DXMT"] * 3 + ["DXVK"] * 3 + ["NONE"] * 2 + [None]
_PERF = ["UNPLAYABLE", "BARELY_PLAYABLE", "PLAYABLE", "GOOD", "VERY_GOOD", "EXCELLENT"]
_SETTINGS = [None, "LOW", "MEDIUM", "HIGH", "ULTRA"]


def _rid(rng):
    return "".join(rng.choice("0123456789abcdef") for _ in range(8)) \
        + "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(17))


def macgamingdb(appid):
    """One /api/rest/games/{appid} answer. Elden Ring uses the recorded file."""
    recorded = DATA / f"macgamingdb-{appid}.json"
    if recorded.exists():
        return recorded.read_bytes()
    if appid == APPID_NO_REPORTS:
        game = {"id": str(appid), "slug": "quiet-game", "name": "A Quiet Game",
                "releaseYear": 2024, "aggregatedPerformance": None, "reviewCount": 0,
                "sourceLinks": [{"source": "steam", "externalId": str(appid)}],
                "createdAt": "2026-09-01 10:00:00", "updatedAt": "2026-10-10T08:00:00.000Z"}
        return json.dumps({"game": game, "reviews": []}, indent=1).encode()
    name, slug, year = next(
        ((n, s, y) for a, n, s, y in FIXTURE_GAMES if a == appid), (f"Game {appid}", f"game-{appid}", 2023))
    rng = random.Random(0xBEEF ^ appid)
    reviews = []
    count = rng.randrange(6, 22)
    center = rng.randrange(2, 6)  # the rating most reports cluster on
    start = datetime.datetime(2025, 3, 1, tzinfo=datetime.timezone.utc)
    for _ in range(count):
        chip, variant = rng.choice(_CHIPS)
        method = rng.choice(_METHODS)
        layer = rng.choice(_LAYERS) if method == "CROSSOVER" else None
        perf = _PERF[min(5, max(0, int(rng.gauss(center, 1))))]
        perf_i = _PERF.index(perf)
        fps = None if rng.random() < 0.3 else max(12, int(rng.gauss(15 + perf_i * 12, 8)))
        created = start + datetime.timedelta(seconds=rng.randrange(0, 500 * 86400))
        reviews.append({
            "id": "c" + _rid(rng),
            "gameId": str(appid),
            "playMethod": method,
            "translationLayer": layer,
            "performance": perf,
            "fps": fps,
            "graphicsSettings": rng.choice(_SETTINGS),
            "resolution": rng.choice(["1920x1080", "1920x1200", "2560x1440", "3024x1964", "1512x982"]),
            "chipset": chip,
            "chipsetVariant": variant,
            "softwareVersion": rng.choice(["24.0", "25.0", "25.1", "26.0"]),
            "createdAt": created.strftime("%Y-%m-%dT%H:%M:%S.000+00:00"),
            "updatedAt": created.strftime("%Y-%m-%dT%H:%M:%S.000+00:00"),
        })
    ratings = [_PERF.index(r["performance"]) for r in reviews]
    agg = _PERF[round(sum(ratings) / len(ratings))] if ratings else None
    game = {"id": str(appid), "slug": slug, "name": name, "releaseYear": year,
            "aggregatedPerformance": agg, "reviewCount": len(reviews),
            "sourceLinks": [{"source": "steam", "externalId": str(appid)}],
            "createdAt": "2025-03-04 08:00:00", "updatedAt": "2026-10-15T04:53:20.313Z"}
    return json.dumps({"game": game, "reviews": reviews}, indent=1).encode()


# ---------------------------------------------------------------- compat.json.gz

_AGW = ["perfect", "playable", "runs", "menu", "unplayable", "unknown", "na"]
_EXTRA_RECORDS = {
    1174180: ("Red Dead Redemption 2", 3, 2, {"crossover": "perfect", "wine": "playable"},
              {"reports": 212, "works": 198, "online_tried": 41, "online_played": 40}),
    1593500: ("God of War", 4, 1, {"crossover": "perfect", "wine": "perfect"},
              {"reports": 340, "works": 331, "online_tried": 0, "online_played": 0}),
    1091500: ("Cyberpunk 2077", 3, 2, {"crossover": "playable", "wine": "playable"},
              {"reports": 428, "works": 390, "online_tried": 12, "online_played": 11}),
    1086940: ("Baldur's Gate 3", 4, 1, {"crossover": "perfect", "wine": "playable"},
              {"reports": 187, "works": 170, "online_tried": 9, "online_played": 9}),
    367520: ("Hollow Knight", 5, 0, {"native": "perfect", "rosetta2": "perfect",
                                     "crossover": "perfect", "wine": "perfect"},
             {"reports": 96, "works": 95, "online_tried": 0, "online_played": 0}),
}


def _compat_document():
    if REPO_TOOLS_COMPAT_GZ.exists():
        doc = json.loads(gzip.decompress(REPO_TOOLS_COMPAT_GZ.read_bytes()))
    else:
        doc = {
            "schema_version": 1,
            "generated": "2026-10-19T03:17:00Z",
            "sources": {
                "applegamingwiki": {
                    "name": "AppleGamingWiki", "credit": "AppleGamingWiki (CC BY-NC-SA 3.0)",
                    "url": "https://www.applegamingwiki.com", "license": "CC BY-NC-SA 3.0",
                    "license_url": "https://creativecommons.org/licenses/by-nc-sa/3.0/",
                    "attribution": "Ratings from AppleGamingWiki contributors, under CC BY-NC-SA 3.0. "
                                   "The ratings in this file are shared under the same license.",
                    "fetched": "2026-10-19", "status": "fresh"},
                "protondb": {
                    "name": "ProtonDB", "credit": "ProtonDB (ODbL)",
                    "url": "https://www.protondb.com", "license": "ODbL",
                    "license_url": "https://opendatacommons.org/licenses/odbl/1-0/",
                    "attribution": "Linux report counts derived from the ProtonDB data export "
                                   "(github.com/bdefore/protondb-data), under the Open Database License. "
                                   "The counts in this file are shared under the same license.",
                    "fetched": "2026-10-19", "status": "fresh", "export": "reports_oct1_2026"},
                "areweanticheatyet": {
                    "name": "AreWeAntiCheatYet", "credit": "AreWeAntiCheatYet (MIT)",
                    "url": "https://areweanticheatyet.com", "license": "MIT",
                    "license_url": "https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet/blob/master/LICENSE",
                    "attribution": "Linux anti-cheat status from AreWeAntiCheatYet. "
                                   "Copyright (c) 2021 Starz0r, Curve. MIT License.",
                    "fetched": "2026-10-19", "status": "fresh"},
            },
            "gpu_strength": json.loads(REPO_GPU_STRENGTH.read_text())
            if REPO_GPU_STRENGTH.exists()
            else {"M1": 1, "M2": 1.35, "M3": 1.6, "M4": 1.9},
            "records": {},
        }
    rng = random.Random(0xCAF)
    for appid, (name, best, worst, ratings, pdb) in _EXTRA_RECORDS.items():
        key = str(appid)
        if key in doc["records"]:
            continue
        all_ratings = {"native": "na", "rosetta2": "unknown", "crossover": "unknown",
                       "wine": "unknown", "parallels": "unknown"}
        all_ratings.update(ratings)
        record = {
            "name": name,
            "applegamingwiki": {
                "fetched": "2026-10-19", "page": name,
                "revision": rng.randrange(4000, 12000), "ratings": all_ratings},
            "protondb": dict(pdb, verdict="runs", fetched="2026-10-01", since="2025-10-01"),
        }
        if appid == 1172470:  # Apex: anti-cheat denied on Linux
            record["areweanticheatyet"] = {
                "fetched": "2026-10-19", "status": "Denied",
                "anticheats": ["Easy Anti-Cheat", "Hyperion"], "native": False,
                "changed": "2024-10-31"}
        doc["records"][key] = record
    if "1172470" in doc["records"]:  # keep Apex's anti-cheat block in every case
        doc["records"]["1172470"].setdefault("areweanticheatyet", {
            "fetched": "2026-10-19", "status": "Denied",
            "anticheats": ["Easy Anti-Cheat", "Hyperion"], "native": False,
            "changed": "2024-10-31"})
    return doc


def compat_gz(variant="fresh"):
    doc = _compat_document()
    if variant == "stale":
        old = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)
        doc = json.loads(json.dumps(doc))
        doc["generated"] = old.strftime("%Y-%m-%dT%H:%M:%SZ")
        for source in doc["sources"].values():
            source["status"] = "stale"
            source["fetched"] = old.strftime("%Y-%m-%d")
    if variant == "corrupt":
        # Still JSON in gzip, but schema-invalid: the app discards it
        broken = {"schema_version": 1, "generated": doc["generated"],
                  "sources": doc["sources"], "gpu_strength": "not-a-map",
                  "records": {"1245620": {"name": "ELDEN RING", "extra": True}}}
        return gzip.compress(json.dumps(broken).encode())
    return gzip.compress(json.dumps(doc).encode())


# ---------------------------------------------------------------- runner manifest

def _archive(archive_name, members, fmt):
    body = io.BytesIO()
    if fmt == "zip":
        with zipfile.ZipFile(body, "w", zipfile.ZIP_DEFLATED) as z:
            for name, payload in members.items():
                z.writestr(name, payload)
    elif fmt == "tar.gz":
        with tarfile.open(fileobj=body, mode="w:gz") as t:
            for name, payload in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                info.mode = 0o755 if payload.startswith(b"#!") or b"\xcf\xfa\xed\xfe" in payload[:4] else 0o644
                t.addfile(info, io.BytesIO(payload))
    elif fmt == "tar.xz":
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as t:
            for name, payload in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                info.mode = 0o755
                t.addfile(info, io.BytesIO(payload))
        body.write(lzma.compress(raw.getvalue()))
    return body.getvalue()


_MACHO_STUB = b"\xcf\xfa\xed\xfe\x07\x00\x00\x01" + b"\x00" * 24 + b"QA stub Mach-O arm64\n"


def _wine_members(root):
    wine = b"#!/bin/sh\n# QA stub wine loader\necho 'wine stub: cannot run in QA' >&2\n"
    return {
        f"{root}/bin/wine": wine,
        f"{root}/bin/wineserver": b"#!/bin/sh\n",
        f"{root}/lib/wine/x86_64-windows/kernel32.dll": b"MZ" + b"\x00" * 62,
        f"{root}/lib/wine/x86_64-unix/libwine.so": _MACHO_STUB,
        f"{root}/VERSION": b"qa-wine\n",
    }


def _dxmt_members():
    dll = b"MZ" + b"\x00" * 62 + b"QA stub DXMT\n"
    return {"x86_64-windows/d3d11.dll": dll, "x86_64-windows/dxgi.dll": dll,
            "x86_64-windows/winemetal.dll": dll, "x86_64-unix/winemetal.so": _MACHO_STUB}


def _dxvk_members():
    dll = b"MZ" + b"\x00" * 62 + b"QA stub DXVK\n"
    return {"x86_64-windows/d3d11.dll": dll, "x86_64-windows/dxgi.dll": dll}


def _app_zip(version):
    plist = (f'<?xml version="1.0"?><plist version="1.0"><dict>'
             f"<key>CFBundleIdentifier</key><string>dev.bryann2k.cartouche</string>"
             f"<key>CFBundleShortVersionString</key><string>{version}</string>"
             f"</dict></plist>").encode()
    return _archive("app.zip", {"Cartouche.app/Contents/Info.plist": plist,
                                "Cartouche.app/Contents/MacOS/Cartouche": _MACHO_STUB}, "zip")


# Release assets: filename -> (bytes built lazily)
def _build_assets():
    assets = {}
    crossover = _archive("wine-crossover.tar.xz", _wine_members("wine"), "tar.xz")
    assets["wine-crossover-26.3.0-1-x86_64.tar.xz"] = crossover
    for bid, root in [("wine-stable-11.0_1-osx64.tar.xz", "Wine Stable.app/Contents/Resources/wine"),
                      ("wine-devel-11.18-osx64.tar.xz", "Wine Devel.app/Contents/Resources/wine")]:
        assets[bid] = _archive(bid, _wine_members(root), "tar.xz")
    assets["dxmt-v0.80-builtin.tar.gz"] = _archive("dxmt.tar.gz", _dxmt_members(), "tar.gz")
    assets["dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"] = \
        _archive("dxvk.tar.gz", _dxvk_members(), "tar.gz")
    for version in (UPDATE_VERSION, BETA_VERSION):
        assets[f"Cartouche-{version}.zip"] = _app_zip(version)
    return assets


ASSETS = _build_assets()


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def runners_json():
    """The published manifest, one revision ahead of the bundled one. The two
    winehq builds keep their shipped pins (a changed pin would be rejected);
    the QA-only build names the fake archive this server serves, so a real
    end-to-end download verifies."""
    crossover = ASSETS["wine-crossover-26.3.0-1-x86_64.tar.xz"]
    return json.dumps({
        "format": 1, "revision": 2,
        "builds": [
            {
                "id": "wine-stable-11.0_1", "kind": "wineBuild", "origin": "winehq",
                "name": "Wine", "version": "11.0_1", "displayVersion": "11.0",
                "url": "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz",
                "size": 185303032,
                "sha256": "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
                "root": "Wine Stable.app/Contents/Resources/wine",
                "loader": "bin/wine", "flavors": ["rosetta"],
            },
            {
                "id": "wine-devel-11.18", "kind": "wineBuild", "origin": "winehq",
                "name": "Wine", "version": "11.18", "displayVersion": "11.18",
                "url": "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz",
                "size": 190974384,
                "sha256": "aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82",
                "root": "Wine Devel.app/Contents/Resources/wine",
                "loader": "bin/wine", "flavors": ["rosetta"],
            },
            {
                "id": "wine-crossover-26.3.0-1", "kind": "wineBuild", "origin": "cartouche",
                "name": "Cartouche Wine", "version": "26.3.0-1", "displayVersion": "26.3",
                "url": "https://github.com/BRYANN2K/cartouche/releases/download/wine-crossover-26.3.0-1/wine-crossover-26.3.0-1-x86_64.tar.xz",
                "size": len(crossover), "sha256": _sha(crossover),
                "root": "wine", "loader": "bin/wine",
                "flavors": ["rosetta", "fex"],
            },
        ],
    }, indent=1).encode()


def backends_json():
    """Backends manifest with QA pins — the bundled backends.json pins real
    GitHub archives; this one pins the fake archives above. The app reads only
    its bundled copy today (BackendManifest.current), so this route is for the
    published-manifest flow when it lands (UPD-04). TO VERIFY."""
    dxmt = ASSETS["dxmt-v0.80-builtin.tar.gz"]
    dxvk = ASSETS["dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"]
    return json.dumps({
        "format": 1, "revision": 2,
        "backends": [
            {
                "backend": "dxmt", "name": "DXMT", "version": "0.80", "license": "MIT",
                "url": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
                "size": len(dxmt), "sha256": _sha(dxmt),
                "files": ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll",
                          "x86_64-windows/winemetal.dll", "x86_64-unix/winemetal.so"],
            },
            {
                "backend": "dxvk", "name": "DXVK", "version": "1.10.3-20230507-repack",
                "license": "Zlib",
                "url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
                "size": len(dxvk), "sha256": _sha(dxvk),
                "files": ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll"],
            },
        ],
    }, indent=1).encode()


# ---------------------------------------------------------------- appcast

_ED_SIG = "GQF06ayCCpIxh8XlQPQYWTwbYO2SckfWqr9rYCuJrqIqa9o4v3lQAfakesignature0="
_FOREIGN_SIG = "AAAAYCCpIxh8XlQPQYWTwbYO2SckfWqr9rYCuJrqIqa9o4v3foreignkey000000="


def _item(version, bundle_version, sig, base, channel=None,
          notes="Bug fixes and small improvements."):
    chan = f"\n    <sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    return f"""  <item>
    <title>Version {version}</title>
    <link>https://cartouche.bryann2k.dev/releases/{version}</link>
    <sparkle:version>{bundle_version}</sparkle:version>
    <sparkle:shortVersionString>{version}</sparkle:shortVersionString>{chan}
    <description><![CDATA[<h2>Cartouche {version}</h2><p>{notes}</p>]]></description>
    <pubDate>Mon, 12 Oct 2026 09:00:00 +0000</pubDate>
    <enclosure url="{base}/BRYANN2K/cartouche/releases/download/v{version}/Cartouche-{version}.zip"
      sparkle:edSignature="{sig}" type="application/octet-stream"/>
  </item>"""


def appcast_xml(armed=frozenset(), base="http://127.0.0.1:8890"):
    """Sparkle feed. Default: only the current version (no update offered).
    update-available adds 0.2.0; update-foreign-key signs it wrong;
    beta-available adds a beta item (it can ride on top of a stable update)."""
    items = []
    if "update-foreign-key" in armed:
        items.append(_item(UPDATE_VERSION, UPDATE_VERSION, _FOREIGN_SIG, base))
    elif "update-available" in armed:
        items.append(_item(UPDATE_VERSION, UPDATE_VERSION, _ED_SIG, base))
    if "beta-available" in armed:
        items.append(_item(BETA_VERSION, BETA_BUNDLE_VERSION, _ED_SIG, base, channel="beta",
                           notes="Beta channel preview."))
    items.append(_item(APP_VERSION, APP_VERSION, _ED_SIG, base))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
 xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
  <title>Cartouche</title>
  <link>https://cartouche.bryann2k.dev</link>
  <description>Cartouche updates</description>
  <language>en</language>
{chr(10).join(items)}
</channel>
</rss>
""".encode()


# ---------------------------------------------------------------- libretro

# core -> (display_name, corename, extensions, systemname, systemid, firmware notes)
_CORE_INFO = {
    "nestopia": ("Nintendo - NES / Famicom (Nestopia UE)", "Nestopia UE", "nes|fds",
                 "Nintendo Entertainment System", "nintendo_entertainment_system", []),
    "snes9x": None,   # recorded file in data/
    "sameboy": None,  # recorded file in data/
    "mgba": ("Nintendo - Game Boy Advance (mGBA)", "mGBA", "gba|gb|gbc|elf|agb|mb",
             "Game Boy Advance", "game_boy_advance", []),
    "melonds": ("Nintendo - DS (melonDS)", "melonDS", "nds|dsi|elf",
                "Nintendo DS", "nintendo_ds", []),
    "genesis_plus_gx": ("Sega - MS/GG/MD/CD (Genesis Plus GX)", "Genesis Plus GX",
                        "mdx|md|smd|gen|bin|cue|iso|sms|bms|gg|sg|68k|sgd|chd|m3u",
                        "Mega Drive - Genesis", "sega_mega_drive", []),
    "mednafen_pce_fast": ("NEC - PC Engine / CD (Beetle PCE FAST)", "Beetle PCE Fast",
                          "pce|sgx|cue|ccd|iso|img|bin|chd", "PC Engine", "pc_engine", []),
    "swanstation": None,  # recorded file in data/
    "stella": ("Atari - 2600 (Stella)", "Stella", "a26|bin", "Atari 2600", "atari_2600", []),
    "mupen64plus_next": ("Nintendo - Nintendo 64 (Mupen64Plus-Next)", "Mupen64Plus-Next",
                         "n64|v64|z64|bin|u1|ndd", "Nintendo 64", "nintendo_64", []),
    "mesen": ("Nintendo - NES / Famicom (Mesen)", "Mesen", "nes|fds|unf|unif",
              "Nintendo Entertainment System", "nintendo_entertainment_system", []),
    "fceumm": ("Nintendo - NES / Famicom (FCEUmm)", "FCEUmm", "fds|nes|unif|unf",
               "Nintendo Entertainment System", "nintendo_entertainment_system", []),
    "bsnes": ("Nintendo - SNES / SFC (bsnes)", "bsnes", "smc|sfc|swc|fig|bs|st",
              "Super Nintendo Entertainment System", "super_nes", []),
    "mesen-s": ("Nintendo - SNES / SFC (Mesen-S)", "Mesen-S", "smc|sfc|swc|fig|bs|st|gb|gbc",
                "Super Nintendo Entertainment System", "super_nes", []),
    "gambatte": ("Nintendo - Game Boy / Color (Gambatte)", "Gambatte", "gb|gbc|dmg",
                 "Game Boy/Game Boy Color", "game_boy", []),
    "vbam": ("Nintendo - Game Boy Advance (VBA-M)", "VBA-M", "dmg|gb|gbc|cgb|sgb|gba|agb|elf|mb",
             "Game Boy Advance", "game_boy_advance", []),
    "desmume": ("Nintendo - DS (DeSmuME)", "DeSmuME", "nds|bin|dsi",
                "Nintendo DS", "nintendo_ds", []),
    "picodrive": ("Sega - 32X/Pico/SV/MD/MDX/SCD/GG (PicoDrive)", "PicoDrive",
                  "bin|gen|smd|md|32x|cue|iso|sms|68k|chd|m3u", "Sega 32X", "sega_32x", []),
    "mednafen_psx_hw": ("Sony - PlayStation (Beetle PSX HW)", "Beetle PSX HW",
                        "exe|cue|ccd|toc|m3u|chd|pbp|ecm", "PlayStation", "playstation",
                        [("scph5500.bin", "8dd7d5296a650fac7319bce665a6a53c"),
                         ("scph5501.bin", "490f666e1afb15b7362b406ed1cea246"),
                         ("scph5502.bin", "32736f17079d0b2b7024407c39bd3050")]),
    "pcsx_rearmed": ("Sony - PlayStation (PCSX ReARMed)", "PCSX ReARMed",
                     "bin|cue|img|mdf|pbp|toc|cbn|m3u|ccd|chd|iso", "PlayStation", "playstation",
                     [("scph5500.bin", "8dd7d5296a650fac7319bce665a6a53c"),
                      ("scph5501.bin", "490f666e1afb15b7362b406ed1cea246"),
                      ("scph5502.bin", "32736f17079d0b2b7024407c39bd3050")]),
    "parallel_n64": ("Nintendo - Nintendo 64 (ParaLLEl N64)", "ParaLLEl N64",
                     "n64|v64|z64|bin|u1|ndd", "Nintendo 64", "nintendo_64", []),
}


def core_info_text(core):
    """The .info file for one core, in libretro's key = "value" shape."""
    recorded = DATA / f"{core}_libretro.info"
    if recorded.exists():
        return recorded.read_text()
    entry = _CORE_INFO.get(core)
    if entry is None:
        entry = (f"{core} core", core, "bin", core, core, [])
    display, corename, exts, sysname, sysid, firmware = entry
    lines = [
        '# Written for the tests in the shape of the libretro .info files',
        f'display_name = "{display}"',
        f'corename = "{corename}"',
        f'supported_extensions = "{exts}"',
        'license = "GPLv3"',
        f'systemname = "{sysname}"',
        f'systemid = "{sysid}"',
        "",
        f"firmware_count = {len(firmware)}",
    ]
    notes = []
    for i, (path, md5) in enumerate(firmware):
        lines += [f'firmware{i}_desc = "{path} (BIOS)"', f'firmware{i}_path = "{path}"',
                  'firmware{i}_opt = "true"']
        notes.append(f"(!) {path} (md5): {md5}")
    if notes:
        lines.append(f'notes = "{"|".join(notes)}"')
    return "\n".join(lines) + "\n"


def info_zip():
    """buildbot /assets/frontend/info.zip with one member per known core."""
    body = io.BytesIO()
    with zipfile.ZipFile(body, "w", zipfile.ZIP_DEFLATED) as z:
        for core in _CORE_INFO:
            z.writestr(f"{core}_libretro.info", core_info_text(core))
    return body.getvalue()


def core_zip(core):
    """buildbot latest/<core>_libretro.dylib.zip: one stub Mach-O member."""
    body = io.BytesIO()
    with zipfile.ZipFile(body, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{core}_libretro.dylib", _MACHO_STUB + f"QA stub {core} core\n".encode())
    return body.getvalue()


def _rdb_write(entries):
    """libretro-db wire format, matching RetroArchKit.RDB.write."""
    out = bytearray(b"RARCHDB" + b"\x00" + b"\x00" * 8)

    def s(v):
        b = v.encode()
        if len(b) < 32:
            out.append(0xA0 | len(b))
        else:
            out.extend(bytes((0xD9, len(b))))
        out.extend(b)

    def blob(b):
        out.extend(bytes((0xC4, len(b))) + b)

    for e in entries:
        fields = []
        if e.get("name"):
            fields.append(("name", "s", e["name"]))
        if e.get("rom_name"):
            fields.append(("rom_name", "s", e["rom_name"]))
        if e.get("size"):
            fields.append(("size", "u64", e["size"]))
        if e.get("crc"):
            fields.append(("crc", "b", int(e["crc"], 16).to_bytes(4, "big")))
        if e.get("md5"):
            fields.append(("md5", "b", bytes.fromhex(e["md5"])))
        if e.get("sha1"):
            fields.append(("sha1", "b", bytes.fromhex(e["sha1"])))
        if e.get("serial"):
            fields.append(("serial", "b", e["serial"].encode()))
        out.append(0x80 | len(fields))
        for key, kind, value in fields:
            s(key)
            if kind == "s":
                s(value)
            elif kind == "u64":
                out.extend(b"\xcf" + value.to_bytes(8, "big"))
            else:
                blob(value)
    out.append(0xC0)
    out[8:16] = len(out).to_bytes(8, "big")
    out.extend(b"\x81")  # trailer map, one field
    s("count")
    out.extend(b"\xcf" + len(entries).to_bytes(8, "big"))
    return bytes(out)


def rdb(system):
    """rdb/<System>.rdb from data/libretro-rows.json; only known systems."""
    rows_file = DATA / "libretro-rows.json"
    if not rows_file.exists():
        return None
    rows = json.loads(rows_file.read_text())
    entries = rows.get(system)
    if entries is None:
        return None
    return _rdb_write(entries)


# ---------------------------------------------------------------- P10 stores
# Shapes marked "to verify after P10 merges": the change bundles legendary,
# gogdl and nile; these stand in for their account/game APIs.

def store_games(store):
    fixture = DATA / "stores" / f"{store}.json"
    if fixture.exists():
        return fixture.read_bytes()
    return b'{"games": []}'


def store_status(store, expired):
    return json.dumps({
        "store": store, "signed_in": not expired, "expired": expired,
        "account": None if expired else "qa-player@example.test",
    }, indent=1).encode()


# ---------------------------------------------------------------- P14 extras
# Marked "to verify after P14 merges": RetroArch speaks to
# retroachievements.org's dorequest.php, and the lobby lists open games.

def ra_dorequest(query, hardcore=False):
    r = query.get("r", [""])[0]
    user = query.get("u", ["qa-player"])[0]
    if r == "login2":
        return {"Success": True, "User": user, "Token": "qa-ra-token-0001",
                "Score": 1337, "Messages": 0, "Permissions": 1,
                "AccountType": "Registered"}
    if r == "gameid":
        return {"Success": True, "GameID": 99901}
    if r in ("patch", "API_GetGameInfoAndUserProgress"):
        ach = [{"ID": 1, "Title": "First Steps", "Description": "Start the game.",
                "Points": 5, "BadgeName": "00001",
                "DateEarned": "2026-10-11 15:23:00",
                "DateEarnedHardcore": "2026-10-11 15:23:00" if hardcore else None},
               {"ID": 2, "Title": "Half Way", "Description": "Reach the middle.",
                "Points": 10, "BadgeName": "00002",
                "DateEarned": None, "DateEarnedHardcore": None}]
        return {"Success": True, "PatchData": {"ID": 99901, "Title": "Cartouche Homebrew",
                "ConsoleID": 4, "ImageIcon": "/Images/99901.png", "Achievements": ach},
                "HardcoreMode": hardcore}
    if r == "achievementcounts":
        return {"Success": True, "GameID": 99901, "AchievementIDs": [1, 2], "Count": 2}
    return {"Success": False, "Error": f"unknown request {r}"}


def lobby_list(friends_game=False):
    rooms = []
    if friends_game:
        rooms.append({
            "id": "room-qa-1", "username": "QAFriend", "game_name": "Cartouche Homebrew",
            "game_crc": "3fa862e9", "core_name": "Snes9x", "core_version": "1.63",
            "subsystem_name": "", "retroarch_version": "1.22.2",
            "frontend": "cartouche-qa", "ip": "192.168.64.5", "port": 55435,
            "host_method": 3, "has_password": False, "has_spectate_password": False,
            "created": "2026-10-19T10:00:00Z", "updated": "2026-10-19T10:00:00Z",
            "country": "US", "connectable": True,
        })
    return json.dumps({"rooms": rooms}, indent=1).encode()
