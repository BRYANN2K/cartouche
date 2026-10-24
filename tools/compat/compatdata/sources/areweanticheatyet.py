"""AreWeAntiCheatYet: anti-cheat status on Linux."""

import json
import re

from .. import urls
from . import Result, expect

STATUSES = {"Supported", "Running", "Planned", "Broken", "Denied"}


def fetch(fetcher, cache, today, previous=None, only=None):
    games = json.loads(fetcher.get(urls.AWACY_GAMES))
    expect(isinstance(games, list), "games.json is not a list")
    result = Result()
    for game in games:
        expect(isinstance(game, dict) and "status" in game and "anticheats" in game,
               f"game without status or anticheats: {str(game)[:80]}")
        app = str((game.get("storeIds") or {}).get("steam") or "")
        if not app.isdigit() or app.startswith("0") or (only and app not in only):
            continue
        cheats = [c.strip() for c in game["anticheats"] if isinstance(c, str) and c.strip()]
        changed = game.get("dateChanged") or ""
        if game["status"] not in STATUSES or not cheats or not re.match(r"\d{4}-\d{2}-\d{2}", changed):
            result.warnings.append(f"areweanticheatyet {app}: skipped, status {game['status']!r}")
            continue
        result.names[app] = game.get("name") or app
        result.blocks[app] = {
            "fetched": today, "status": game["status"], "anticheats": cheats,
            "native": bool(game.get("native")), "changed": changed[:10],
        }
    return result
