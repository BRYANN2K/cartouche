"""Record test fixtures for a few games from the live sources.

    python3 tools/compat/record_fixtures.py OUT_DIR [--protondb-export reports.tar.gz]

Each file keeps the shape the source serves, cut down to the fixture games.
Text written by people (report notes, wiki prose, store descriptions) and
anything that names a user is left out, so the fixtures carry only the values
the builder reads. fixtures/README.md says what was cut and under which license
each part is.
"""

import argparse
import datetime
import io
import json
import pathlib
import re
import sys
import tarfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from compatdata import http, urls  # noqa: E402
from compatdata.sources.protondb import export_date  # noqa: E402

# MacGamingDB is recorded for the app's tests only. The builder never reads it.
MGDB_GAME = "https://macgamingdb.app/api/rest/games/{}"

GAMES = ["1245620", "1172470", "730", "632470"]
TITLES = {"1245620": "Elden Ring", "1172470": "Apex Legends", "730": "Counter-Strike 2",
          "632470": "Disco Elysium"}

REVIEW_KEYS = ["id", "gameId", "playMethod", "translationLayer", "performance", "fps",
               "graphicsSettings", "resolution", "chipset", "chipsetVariant", "softwareVersion",
               "createdAt", "updatedAt"]
GAME_KEYS = ["id", "slug", "name", "releaseYear", "aggregatedPerformance", "reviewCount",
             "sourceLinks", "createdAt", "updatedAt"]
PROTONDB_RESPONSES = ["verdict", "onlineMultiplayerAttempted", "onlineMultiplayerPlayed"]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1, ensure_ascii=False) + "\n")


def record_steam(fetch, out):
    write(out / "steam" / "most-played.json", json.loads(fetch.get(urls.STEAM_MOST_PLAYED)))


# One game is enough for the app's tests, and keeps the least MacGamingDB data in the repository
MGDB_GAMES = ["1245620"]


def record_mgdb(fetch, out):
    for game in MGDB_GAMES:
        try:
            body = json.loads(fetch.get(MGDB_GAME.format(game)))
        except http.Unavailable as error:
            print(f"macgamingdb {game}: {error}")
            continue
        body["game"] = {k: body["game"][k] for k in GAME_KEYS if k in body["game"]}
        body["reviews"] = [{k: r.get(k) for k in REVIEW_KEYS} for r in body["reviews"]]
        write(out / "macgamingdb" / "games" / f"{game}.json", body)


def wiki_blocks(text):
    """The infobox and the macOS compatibility template, without the rest of the page."""
    keep = []
    for name in ("Infobox game", "Compatibility/macOS"):
        start = text.find("{{" + name)
        if start < 0:
            continue
        depth, i = 0, start
        while i < len(text):
            if text.startswith("{{", i):
                depth, i = depth + 1, i + 2
            elif text.startswith("}}", i):
                depth, i = depth - 1, i + 2
                if depth == 0:
                    break
            else:
                i += 1
        block = text[start:i]
        if name == "Compatibility/macOS":
            # Notes are prose by wiki authors, and the builder does not read them
            block = re.sub(r"(?m)^(\|[a-z0-9 -]+ notes *=).*$", r"\1", block)
        keep.append(block)
    return "\n\n".join(keep) + "\n"


def record_agw(fetch, out):
    pages, cont = [], None
    while True:
        body = json.loads(fetch.get(urls.AGW_API, urls.agw_listing(cont)))
        pages += body["query"]["pages"]
        if "continue" not in body:
            break
        cont = body["continue"]
    wanted = set(TITLES.values())
    chosen = [p for p in pages if p["title"] in wanted]
    write(out / "applegamingwiki" / "listing.json", {"batchcomplete": True, "query": {"pages": chosen}})
    body = json.loads(fetch.get(urls.AGW_API, urls.agw_content([p["pageid"] for p in chosen])))
    for page in body["query"]["pages"]:
        slot = page["revisions"][0]["slots"]["main"]
        slot["content"] = wiki_blocks(slot["content"])
    write(out / "applegamingwiki" / "content.json", body)


def record_protondb(fetch, out, export):
    listing = json.loads(fetch.get(urls.PROTONDB_LISTING))
    newest = sorted(listing, key=lambda e: export_date(e.get("name", "")) or datetime.date.min)[-3:]
    write(out / "protondb" / "listing.json",
          [{k: e[k] for k in ("name", "path", "size", "download_url", "type")} for e in newest])
    if export:
        data = pathlib.Path(export).read_bytes()
    else:
        latest = max(listing, key=lambda e: export_date(e["name"]) or datetime.date.min)
        data = fetch.get(latest["download_url"], timeout=600)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith(".json"))
        reports = json.load(tar.extractfile(member))
    # The builder counts one year back from the newest report. Three more months
    # show that older reports are left out.
    cutoff = max(r["timestamp"] for r in reports) - 456 * 86400
    kept = []
    for report in reports:
        app = report.get("app", {}).get("steam", {}).get("appId")
        if app in GAMES and report["timestamp"] >= cutoff:
            kept.append({
                "app": {"steam": {"appId": app}, "title": report["app"].get("title")},
                "responses": {k: report["responses"][k] for k in PROTONDB_RESPONSES
                              if k in report.get("responses", {})},
                "timestamp": report["timestamp"],
            })
    lines = ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in kept)
    path = out / "protondb" / "reports_piiremoved.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"[\n{lines}\n]\n")


def record_awacy(fetch, out):
    games = json.loads(fetch.get(urls.AWACY_GAMES))
    kept = [g for g in games if (g.get("storeIds") or {}).get("steam") in GAMES]
    for game in kept:
        game.pop("notes", None)
    write(out / "areweanticheatyet" / "games.json", kept)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--protondb-export", help="a downloaded reports_*.tar.gz, to skip the 70 MB download")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    fetch = http.Fetcher()
    record_steam(fetch, out)
    record_mgdb(fetch, out)
    record_agw(fetch, out)
    record_protondb(fetch, out, args.protondb_export)
    record_awacy(fetch, out)
    print(f"recorded into {out} with {fetch.requests} requests")


if __name__ == "__main__":
    main()
