"""ProtonDB: Linux reports from the monthly ODbL export, counted per game."""

import collections
import datetime
import io
import json
import re
import tarfile

from .. import urls
from . import Result, expect

MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
WINDOW_DAYS = 365


def export_date(name):
    """reports_oct1_2026.tar.gz -> 2026-10-01"""
    match = re.fullmatch(r"reports_([a-z]{3})(\d{1,2})_(\d{4})\.tar\.gz", name or "")
    if not match or match[1] not in MONTHS:
        return None
    return datetime.date(int(match[3]), MONTHS.index(match[1]) + 1, int(match[2]))


def verdict(reports, works):
    if works * 4 >= reports * 3:
        return "runs"
    if works * 4 <= reports:
        return "doesnt_run"
    return "mixed"


def fetch(fetcher, cache, today, previous=None, only=None):
    listing = json.loads(fetcher.get(urls.PROTONDB_LISTING))
    expect(isinstance(listing, list), "export listing is not a list")
    exports = [e for e in listing if isinstance(e, dict) and export_date(e.get("name"))]
    expect(exports, "no reports_<month><day>_<year>.tar.gz in the export listing")
    latest = max(exports, key=lambda e: export_date(e["name"]))
    name = latest["name"]
    key = f"protondb/{name}"
    summary = cache.get(key)
    if summary is None:
        data = fetcher.get(latest["download_url"], timeout=900)
        summary = summarize(read_export(data), export_date(name))
        cache.put(key, summary)
    result = Result(meta={"export": name[:-len(".tar.gz")]})
    for app, counts in summary["games"].items():
        if only and app not in only:
            continue
        result.names[app] = counts.pop("title", None) or app
        result.blocks[app] = dict(counts, fetched=summary["date"], since=summary["since"])
    return result


def read_export(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        member = next((m for m in tar.getmembers() if m.name.endswith(".json")), None)
        expect(member is not None, "export without a .json file")
        reports = json.load(tar.extractfile(member))
    expect(isinstance(reports, list), "export is not a list of reports")
    return reports


def summarize(reports, date):
    since = date - datetime.timedelta(days=WINDOW_DAYS)
    start = datetime.datetime.combine(since, datetime.time(), datetime.timezone.utc).timestamp()
    counts = collections.defaultdict(lambda: {"reports": 0, "works": 0, "online_tried": 0,
                                              "online_played": 0, "title": None})
    for report in reports:
        expect(isinstance(report, dict) and "timestamp" in report, "report without timestamp")
        app = str(report.get("app", {}).get("steam", {}).get("appId", ""))
        if not app.isdigit() or app.startswith("0") or report["timestamp"] < start:
            continue
        answers = report.get("responses") or {}
        if answers.get("verdict") not in ("yes", "no"):
            continue
        game = counts[app]
        game["title"] = game["title"] or report.get("app", {}).get("title")
        game["reports"] += 1
        game["works"] += answers["verdict"] == "yes"
        if answers.get("onlineMultiplayerAttempted") == "yes":
            game["online_tried"] += 1
            game["online_played"] += answers.get("onlineMultiplayerPlayed") == "yes"
    games = {}
    for app, game in counts.items():
        game["verdict"] = verdict(game["reports"], game["works"])
        games[app] = game
    return {"date": date.isoformat(), "since": since.isoformat(), "games": games}
