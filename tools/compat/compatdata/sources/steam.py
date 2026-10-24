"""Steam's most played games, so popular games get a record even with no Mac report."""

import json

from .. import urls
from . import expect


def most_played(fetcher):
    body = json.loads(fetcher.get(urls.STEAM_MOST_PLAYED))
    ranks = body.get("response", {}).get("ranks")
    expect(isinstance(ranks, list), "most played answer without ranks")
    return [str(r["appid"]) for r in ranks if isinstance(r, dict) and str(r.get("appid", "")).isdigit()]
