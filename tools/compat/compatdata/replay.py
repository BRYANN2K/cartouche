"""Serve recorded fixtures at the sources' own addresses, so a build runs offline."""

import io
import json
import pathlib
import tarfile

from . import http, urls

PROTONDB_RAW = "https://raw.githubusercontent.com/bdefore/protondb-data/"


class FixtureFetcher:
    def __init__(self, root, down=()):
        self.root = pathlib.Path(root)
        self.down = set(down)
        self.requests = []

    def _read(self, *parts):
        path = self.root.joinpath(*parts)
        if not path.exists():
            raise http.Unavailable(f"{path.name}: HTTP 404")
        return path.read_bytes()

    def _source(self, url):
        if url.startswith(urls.STEAM_MOST_PLAYED):
            return "steam"
        if url.startswith(urls.AGW_API):
            return "applegamingwiki"
        if url.startswith(urls.PROTONDB_LISTING) or url.startswith(PROTONDB_RAW):
            return "protondb"
        if url.startswith(urls.AWACY_GAMES):
            return "areweanticheatyet"
        return None

    def get(self, url, params=None, timeout=None):
        self.requests.append((url, dict(params or {})))
        source = self._source(url)
        if source is None:
            raise http.Unavailable(f"{url}: no fixture for this address")
        if source in self.down:
            raise http.Unavailable(f"{url}: connection refused (simulated)")
        if source == "steam":
            return self._read("steam", "most-played.json")
        if source == "applegamingwiki":
            if (params or {}).get("generator") == "embeddedin":
                return self._read("applegamingwiki", "listing.json")
            wanted = {int(p) for p in params["pageids"].split("|")}
            body = json.loads(self._read("applegamingwiki", "content.json"))
            body["query"]["pages"] = [p for p in body["query"]["pages"] if p["pageid"] in wanted]
            return json.dumps(body).encode()
        if url == urls.PROTONDB_LISTING:
            return self._read("protondb", "listing.json")
        if source == "protondb":
            return self._export()
        return self._read("areweanticheatyet", "games.json")

    def _export(self):
        data = self._read("protondb", "reports_piiremoved.json")
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w:gz") as tar:
            info = tarfile.TarInfo("reports_piiremoved.json")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        return out.getvalue()
