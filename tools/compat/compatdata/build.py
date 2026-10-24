"""Merge the sources into one compat.json, keyed by Steam App ID."""

import datetime
import gzip
import json
import pathlib

from . import http, schema
from .sources import FormatError, applegamingwiki, areweanticheatyet, protondb, steam

GPU_STRENGTH = pathlib.Path(__file__).resolve().parent.parent / "gpu_strength.json"
MAX_BYTES = 25 * 1000 * 1000

SOURCES = {
    "applegamingwiki": {
        "module": applegamingwiki,
        "name": "AppleGamingWiki",
        "credit": "AppleGamingWiki (CC BY-NC-SA 3.0)",
        "url": "https://www.applegamingwiki.com",
        "license": "CC BY-NC-SA 3.0",
        "license_url": "https://creativecommons.org/licenses/by-nc-sa/3.0/",
        "attribution": "Ratings from AppleGamingWiki contributors, under CC BY-NC-SA 3.0. "
                       "The ratings in this file are shared under the same license.",
    },
    "protondb": {
        "module": protondb,
        "name": "ProtonDB",
        "credit": "ProtonDB (ODbL)",
        "url": "https://www.protondb.com",
        "license": "ODbL",
        "license_url": "https://opendatacommons.org/licenses/odbl/1-0/",
        "attribution": "Linux report counts derived from the ProtonDB data export "
                       "(github.com/bdefore/protondb-data), under the Open Database License. "
                       "The counts in this file are shared under the same license.",
    },
    "areweanticheatyet": {
        "module": areweanticheatyet,
        "name": "AreWeAntiCheatYet",
        "credit": "AreWeAntiCheatYet (MIT)",
        "url": "https://areweanticheatyet.com",
        "license": "MIT",
        "license_url": "https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet/blob/master/LICENSE",
        "attribution": "Linux anti-cheat status from AreWeAntiCheatYet. "
                       "Copyright (c) 2021 Starz0r, Curve. MIT License.",
    },
}

# MacGamingDB publishes no data license, so the file never carries it: the app
# reads it live. The file covers games people play: Steam's top games, every game
# in these sources, and games with enough recent ProtonDB reports.
LISTED = ("applegamingwiki", "areweanticheatyet")
PROTONDB_LISTED = 10


class BuildFailed(Exception):
    pass


def build(fetcher, cache, now, previous=None, only=None, log=print):
    today = now.date().isoformat()
    previous = previous or {}
    old_records = previous.get("records", {})
    results, sources = {}, {}

    try:
        wanted = set(steam.most_played(fetcher))
    except http.Unavailable as error:
        log(f"steam: {error}. Building from the previous file's games instead of the top list.")
        wanted = set(old_records)
    if only:
        wanted &= only

    for key, info in SOURCES.items():
        old_blocks = {app: rec[key] for app, rec in old_records.items() if key in rec}
        meta = {k: v for k, v in info.items() if k != "module"}
        try:
            result = info["module"].fetch(fetcher, cache, today, previous=old_blocks, only=only)
        except http.Unavailable as error:
            old_source = previous.get("sources", {}).get(key)
            if not old_source:
                raise BuildFailed(f"{key} is down and there is no previous file to keep its records from: {error}")
            log(f"{key}: {error}. Keeping {len(old_blocks)} records from {old_source['fetched']}.")
            results[key] = {"blocks": old_blocks, "names": {}}
            sources[key] = dict(meta, fetched=old_source["fetched"], status="stale",
                                **({"export": old_source["export"]} if "export" in old_source else {}))
            continue
        except FormatError as error:
            raise BuildFailed(f"{key} answered in a format the builder does not know: {error}") from error
        for warning in result.warnings[:20]:
            log(warning)
        if len(result.warnings) > 20:
            log(f"{key}: {len(result.warnings) - 20} more warnings")
        results[key] = {"blocks": result.blocks, "names": result.names}
        sources[key] = dict(meta, fetched=today, status="fresh", **result.meta)

    for key in LISTED:
        wanted |= set(results[key]["blocks"])
    wanted |= {app for app, block in results["protondb"]["blocks"].items() if block["reports"] >= PROTONDB_LISTED}
    if only:
        wanted &= only

    records = {}
    for app in sorted(wanted, key=int):
        record = {}
        for key in SOURCES:
            if app in results[key]["blocks"]:
                record[key] = results[key]["blocks"][app]
        if not record:
            continue
        name = next((results[k]["names"].get(app) for k in SOURCES if results[k]["names"].get(app)), None)
        name = name or old_records.get(app, {}).get("name") or app
        records[app] = {"name": name, **record}

    document = {
        "schema_version": 1,
        "generated": now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": sources,
        "gpu_strength": json.loads(GPU_STRENGTH.read_text()),
        "records": records,
    }
    problems = schema.errors(document, schema.load())
    if problems:
        raise BuildFailed("the file does not match the schema:\n  " + "\n  ".join(problems[:30]))
    return document


def encode(document):
    raw = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
    packed = gzip.compress(raw, compresslevel=9, mtime=0)
    if len(packed) > MAX_BYTES:
        raise BuildFailed(f"compat.json.gz is {len(packed)} bytes, over the {MAX_BYTES} byte limit")
    return raw, packed


def load_previous(path):
    if not path:
        return None
    path = pathlib.Path(path)
    if not path.exists():
        return None
    data = path.read_bytes()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    document = json.loads(data)
    problems = schema.errors(document, schema.load())
    if problems:
        raise BuildFailed(f"the previous file {path} does not match the schema: {problems[0]}")
    return document
