"""AppleGamingWiki: the {{Compatibility/macOS}} rating per method, read from each
page's wikitext because the wiki does not answer Cargo queries."""

import json
import re

from .. import urls
from . import Result, expect

FIELDS = {"native": "native", "rosetta 2": "rosetta2", "crossover": "crossover",
          "wine": "wine", "parallels": "parallels"}
# The values of the wiki's {{Rating}} template
RATINGS = {"perfect", "playable", "runs", "menu", "unplayable", "unknown", "na"}
BATCH = 50
MAX_LISTING_PAGES = 50


def fetch(fetcher, cache, today, previous=None, only=None):
    pages = listing(fetcher)
    result = Result()
    parsed, missing = {}, []
    for page in pages:
        cached = cache.get(_key(page))
        if cached is None:
            missing.append(page)
        else:
            parsed[page["pageid"]] = cached
    for start in range(0, len(missing), BATCH):
        batch = missing[start:start + BATCH]
        body = json.loads(fetcher.get(urls.AGW_API, urls.agw_content([p["pageid"] for p in batch])))
        expect(isinstance(body.get("query", {}).get("pages"), list), "revisions answer without pages")
        for item in body["query"]["pages"]:
            page = next((p for p in batch if p["pageid"] == item.get("pageid")), None)
            if page is None or "revisions" not in item:
                continue
            revision = item["revisions"][0]
            content = revision.get("slots", {}).get("main", {}).get("content")
            expect(isinstance(content, str), f"page {item.get('title')} without wikitext")
            entry = parse_page(content, result.warnings, item.get("title"))
            entry.update(title=item["title"], revision=revision.get("revid") or page["lastrevid"])
            cache.put(_key(page), entry)
            parsed[page["pageid"]] = entry

    # When two pages give one App ID (an old game page and its remaster's, say), the
    # most recently edited page wins
    for pageid in sorted(parsed, key=lambda p: (-parsed[p]["revision"], p)):
        entry = parsed[pageid]
        for app in entry.get("appids", []):
            if only and app not in only:
                continue
            if app in result.blocks:
                result.warnings.append(f"applegamingwiki: {app} is on two pages, kept {result.names[app]}")
                continue
            result.names[app] = entry["title"]
            result.blocks[app] = {
                "fetched": today, "page": entry["title"], "revision": entry["revision"],
                "ratings": entry["ratings"],
            }
    return result


def _key(page):
    return f"applegamingwiki/{page['pageid']}/{page['lastrevid']}"


def listing(fetcher):
    pages, cont = [], None
    for _ in range(MAX_LISTING_PAGES):
        body = json.loads(fetcher.get(urls.AGW_API, urls.agw_listing(cont)))
        found = body.get("query", {}).get("pages")
        expect(isinstance(found, list), "embeddedin answer without pages")
        for page in found:
            expect("pageid" in page and "lastrevid" in page and "title" in page,
                   f"listed page without id, revision or title: {page!r}")
            pages.append(page)
        cont = body.get("continue")
        if not cont:
            return pages
    raise RuntimeError("applegamingwiki listing did not end")


def template(text, name):
    """The parameters of the first {{name ...}} in text, split at its own pipes."""
    match = re.search(r"\{\{\s*" + re.escape(name) + r"\s*\|", text)
    if not match:
        return None
    params, current, depth, i = [], [], 1, match.end()
    while i < len(text) and depth > 0:
        pair = text[i:i + 2]
        if pair in ("{{", "[["):
            depth += 1
            current.append(pair)
            i += 2
        elif pair in ("}}", "]]"):
            depth -= 1
            if depth > 0:
                current.append(pair)
            i += 2
        elif text[i] == "|" and depth == 1:
            params.append("".join(current))
            current = []
            i += 1
        else:
            current.append(text[i])
            i += 1
    params.append("".join(current))
    values = {}
    for param in params:
        key, sep, value = param.partition("=")
        if sep:
            values[key.strip().lower()] = value.strip()
    return values


def parse_page(text, warnings, title):
    compat = template(text, "Compatibility/macOS")
    infobox = template(text, "Infobox game") or {}
    ids = re.findall(r"\d+", infobox.get("steam appid", ""))
    if compat is None:
        warnings.append(f"applegamingwiki {title}: no Compatibility/macOS template")
        return {"appids": []}
    ratings = {}
    for field, key in FIELDS.items():
        value = re.sub(r"<!--.*?-->", "", compat.get(field, ""), flags=re.S).strip().lower()
        if value not in RATINGS:
            if value:
                warnings.append(f"applegamingwiki {title}: {field} = {value!r} read as unknown")
            value = "unknown"
        ratings[key] = value
    return {"appids": [i.lstrip("0") for i in ids if i.lstrip("0")], "ratings": ratings}
