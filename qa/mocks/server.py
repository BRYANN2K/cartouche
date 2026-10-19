#!/usr/bin/env python3
"""Cartouche QA mock server: one local stand-in for every external service.

    python3 qa/mocks/server.py --port 8890

Binds 127.0.0.1 only. Routes match the *paths* of the real services, so the QA
harness can point each base URL at this server (SUFeedURL, MacGamingDBClient.api,
CoreSource, DatabaseSource, Thumbnails.base, the store and lobby clients).
Pinned-download URLs in manifests stay on github.com: the QA harness maps that
host to the mock (see README.md).

GET  /__control            lists the mock scenario names and the armed set
POST /__control/<name>     arms one scenario (e.g. net-down, compat-corrupt)
DELETE /__control/<name>   disarms it
POST /__control/clear      disarms everything
POST /__control/reset-fetch  clears the request log and per-run counters
GET  /__control/state      full state for the harness and the other fakes
GET  /__control/requests   the request log

Every scenario name from qa/scenarios.md is accepted. Names whose effect lives
in another fake (fake Steam, fake TCC, the QA home) are recorded and reported
by /__control/state; the ones with an HTTP effect act on the routes below.
"""

import argparse
import gzip
import io
import json
import sys
import tarfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402

SLOW_SECONDS = 3

# name -> effect. Parameterized names are declared in PARAMETRIZED.
SCENARIOS = {
    "net-down": "every external service answers 503; /__control still answers",
    "offline": "alias of net-down (task shorthand)",
    "slow": f"every external route waits {SLOW_SECONDS} s before answering",
    "corrupt-download": "release assets and archives serve corrupted bytes (SHA-256 mismatch)",
    "empty-library": "list endpoints answer empty; no MacGamingDB game exists",
    "steam-closed": "recorded: the fake Steam quits (effect lives in the QA home)",
    "steam-absent": "recorded: Steam was never installed (QA home)",
    "homebrew-absent": "recorded: brew missing (QA home)",
    "homebrew-present": "recorded: brew available (QA home)",
    "compat-stale": "compat.json.gz serves a 40-day-old file with stale sources",
    "compat-corrupt": "compat.json.gz serves schema-invalid JSON",
    "macgamingdb-down": "/api/rest/games/* answers 503; the app keeps its cache",
    "installer-good": "recorded: multi-part Inno fixture (QA home)",
    "installer-missing-part": "recorded: Inno fixture minus a required part (QA home)",
    "installer-optional-part": "recorded: manifest marks the missing part optional (QA home)",
    "installer-stuck": "recorded: installer folder stops growing (QA home)",
    "installer-fail-unarc": "recorded: installer exits with unarc.dll in the log (QA home)",
    "installer-gog": "recorded: goggame info present (QA home)",
    "installer-redist": "recorded: _Redist bundled (QA home)",
    "installer-wrong-match": "recorded: first match is wrong (QA home)",
    "crash-missing-dll": "recorded: next launch crashes naming the DLL (QA home)",
    "fps-session": "recorded: running game reports 60 fps (QA home)",
    "injection-blocked": "recorded: frame counter cannot inject (QA home)",
    "update-available": "appcast offers a newer stable build",
    "update-foreign-key": "appcast offers a build signed with a foreign EdDSA key",
    "beta-available": "appcast adds a beta-channel item",
    "bios-missing": "recorded: PS1 scph5501.bin absent (QA home)",
    "bios-present": "recorded: PS1 scph5501.bin present (QA home)",
    "ra-no-mcp": "RetroArch_Metal.dmg serves the no-MCP build marker",
    "ra-hardcore": "RetroAchievements answers mark hardcore active; recorded for QA home",
    "netplay-lobby": "the lobby lists a friend's game",
    "icloud-synced-state": "recorded: a state synced 'from another Mac' (QA home)",
    "controller-dualsense": "recorded: virtual DualSense, battery 82% (QA home)",
    "perm-appmgmt-denied": "recorded: fake TCC denies App Management (QA home)",
    "perm-downloads-denied": "recorded: fake TCC denies Downloads (QA home)",
    "perm-inputmon-later": "recorded: fake TCC answers Later for Input Monitoring (QA home)",
    "agent-pending-approval": "recorded: an MCP install request waits for approval (QA home)",
    "onboarding-reset": "recorded: onboarding shows again at next launch (QA home)",
}

PARAMETRIZED = {
    "store-token-expired": {"epic", "gog", "amazon"},
    "download-running": None,   # any appid
    "download-done": None,
}

ACTIONS = {"clear", "reset-fetch"}

STORES = ("epic", "gog", "amazon")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.armed = set()
        self.expired_stores = set()
        self.downloads = {}          # appid -> "running" | "done"
        self.requests = []           # (t, method, path, status)
        self.fetch_resets = 0

    def log(self, method, path, status):
        with self.lock:
            self.requests.append({
                "t": time.strftime("%H:%M:%S"), "method": method,
                "path": path, "status": status})
            if len(self.requests) > 5000:
                del self.requests[:1000]

    def arm(self, name):
        """Returns (ok, detail). Parameterized names route to their stores."""
        if ":" in name:
            base, _, param = name.partition(":")
            allowed = PARAMETRIZED.get(base)
            if allowed is None and base not in PARAMETRIZED:
                return False, f"unknown scenario {name}"
            if base == "store-token-expired":
                if param not in allowed:
                    return False, f"store must be one of {sorted(allowed)}"
                with self.lock:
                    self.expired_stores.add(param)
                return True, f"{param} token expired"
            if base in ("download-running", "download-done"):
                if not param.isdigit():
                    return False, "download scenario wants an appid"
                with self.lock:
                    self.downloads[param] = "running" if base == "download-running" else "done"
                return True, f"download {param} {self.downloads[param]}"
        if name not in SCENARIOS:
            return False, f"unknown scenario {name}"
        if name == "offline":
            name = "net-down"
        with self.lock:
            self.armed.add(name)
        return True, f"armed {name}"

    def disarm(self, name):
        if ":" in name:
            base, _, param = name.partition(":")
            if base == "store-token-expired":
                with self.lock:
                    self.expired_stores.discard(param)
                return True
            if base in ("download-running", "download-done"):
                with self.lock:
                    self.downloads.pop(param, None)
                return True
        if name == "offline":
            name = "net-down"
        with self.lock:
            self.armed.discard(name)
        return True

    def snapshot(self):
        with self.lock:
            return {
                "armed": sorted(self.armed),
                "expired_stores": sorted(self.expired_stores),
                "downloads": dict(self.downloads),
                "fetch_resets": self.fetch_resets,
                "request_count": len(self.requests),
            }


class Handler(BaseHTTPRequestHandler):
    server_version = "CartoucheQAMock/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def state(self):
        return self.server.state

    # ---------------------------------------------------------------- plumbing

    def log_message(self, fmt, *args):
        pass  # the request log replaces stderr chatter

    def _send(self, status, body=b"", ctype="application/octet-stream", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        if not self.path.startswith("/__control"):
            self.state.log(self.command, self.path, status)

    def _json(self, obj, status=200):
        self._send(status, json.dumps(obj, indent=1).encode(), "application/json")

    def _path(self):
        parts = urllib.parse.urlsplit(self.path)
        return urllib.parse.unquote(parts.path), urllib.parse.parse_qs(parts.query)

    def _external_gate(self):
        """Global scenario effects. Returns True when the request was answered."""
        if "net-down" in self.state.armed:
            self._send(503, b"QA mock: net-down\n", "text/plain")
            return True
        if "slow" in self.state.armed:
            time.sleep(SLOW_SECONDS)
        return False

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    # ---------------------------------------------------------------- routing

    def _dispatch(self):
        path, query = self._path()
        if path == "/":
            return self._json({"service": "cartouche-qa-mock",
                               "control": f"http://127.0.0.1:{self.server.server_port}/__control",
                               "docs": "qa/mocks/README.md"})
        if path == "/__control" or path.startswith("/__control/"):
            return self._control(path)
        if self._external_gate():
            return
        try:
            body, ctype, status = self._route(path, query)
        except Exception as error:  # a broken route must look like a server bug, not a hang
            body, ctype, status = f"mock error: {error}\n".encode(), "text/plain", 500
        self._send(status, body, ctype)

    def _route(self, path, query):
        low = path.lower()

        # MacGamingDB (live per game; app/Compatibility/MacGamingDB.swift)
        if "/api/rest/games/" in low:
            if "macgamingdb-down" in self.state.armed:
                return b"mock: MacGamingDB is down\n", "text/plain", 503
            tail = low.rsplit("/api/rest/games/", 1)[1].strip("/")
            appid = tail.split("/")[0]
            if "empty-library" in self.state.armed:
                return b"not found\n", "text/plain", 404
            if appid.isdigit() and int(appid) == fixtures.APPID_SERVER_ERROR:
                return b"Internal Server Error\n", "text/plain", 500
            known = set(fixtures.GAME_NAMES) | {fixtures.APPID_NO_REPORTS}
            if appid.isdigit() and int(appid) in known:
                return fixtures.macgamingdb(int(appid)), "application/json", 200
            return b"not found\n", "text/plain", 404

        # Nightly compat file + runner manifest (CompatibilityClient.feed,
        # RunnerManifest.feed) — the release-asset path shape
        if low.endswith("compat-data/compat.json.gz") or low.endswith("/compat.json.gz"):
            if "compat-corrupt" in self.state.armed:
                return fixtures.compat_gz("corrupt"), "application/gzip", 200
            if "compat-stale" in self.state.armed:
                return fixtures.compat_gz("stale"), "application/gzip", 200
            if "empty-library" in self.state.armed:
                doc = json.loads(gzip.decompress(fixtures.compat_gz()))
                doc["records"] = {}
                return gzip.compress(json.dumps(doc).encode()), "application/gzip", 200
            return fixtures.compat_gz(), "application/gzip", 200
        if low.endswith("compat-data/runners.json") or low.endswith("/runners.json"):
            return fixtures.runners_json(), "application/json", 200
        if low.endswith("compat-data/backends.json") or low.endswith("/backends.json"):
            return fixtures.backends_json(), "application/json", 200

        # Sparkle appcast (SUFeedURL; channels per UpdateChannel.swift)
        if low.endswith("/appcast.xml"):
            base = f"http://127.0.0.1:{self.server.server_port}"
            return fixtures.appcast_xml(self.state.armed, base), "application/rss+xml", 200

        # GitHub release assets the app downloads (wine, DXMT, DXVK, app zips).
        # A name containing "tampered" always serves corrupted bytes — the
        # damaged-download scenario without needing a control call.
        if "/releases/download/" in low or "/tampered/" in low:
            name = path.rsplit("/", 1)[-1]
            if name in fixtures.ASSETS:
                body = fixtures.ASSETS[name]
                if "corrupt-download" in self.state.armed or "tampered" in low:
                    body = _corrupt(body)
                return body, "application/octet-stream", 200
            if "tampered" in low:
                return _corrupt(b"QA tampered archive\n" * 16), "application/octet-stream", 200
            return b"no such release asset\n", "text/plain", 404

        # libretro buildbot cores + info.zip (RetroArchKit CoreSource)
        if "/assets/frontend/info.zip" in low:
            return fixtures.info_zip(), "application/zip", 200
        if "/nightly/apple/osx/arm64/" in low:
            name = path.rsplit("/", 1)[-1]
            if name.endswith("_libretro.dylib.zip"):
                core = name[: -len("_libretro.dylib.zip")]
                body = fixtures.core_zip(core)
                if "corrupt-download" in self.state.armed:
                    body = _corrupt(body)
                return body, "application/zip", 200
            return b"no such core\n", "text/plain", 404

        # Official RetroArch release dmg (OfficialRelease.url)
        if low.endswith("retroarch_metal.dmg"):
            marker = b"NO-MCP" if "ra-no-mcp" in self.state.armed else b"WITH-MCP"
            return (b"QA stub RetroArch_Metal.dmg " + marker + b"\n" +
                    b"This is a placeholder: not mountable.\n"), "application/x-apple-diskimage", 200

        # libretro-database (ContentDatabase/DatabaseSource)
        if low.endswith(".rdb"):
            system = path.rsplit("/", 1)[-1][:-4]
            body = fixtures.rdb(system)
            if body is None:
                return b"no such system in the mock database\n", "text/plain", 404
            return body, "application/octet-stream", 200

        # libretro-thumbnails (Thumbnails.url)
        if "/named_" in low and low.endswith(".png"):
            parts = path.strip("/").split("/")
            i = next((i for i, p in enumerate(parts) if p.startswith("Named_")), None)
            if i is None or i == 0 or i + 1 >= len(parts):
                return b"bad thumbnail path\n", "text/plain", 404
            system, kind, name = parts[i - 1], parts[i], parts[i + 1][:-4]
            if "empty-library" in self.state.armed:
                return b"not found\n", "text/plain", 404
            return fixtures.thumbnail_png(system, kind, name), "image/png", 200

        # Steam CDN covers (CoverStore.cdn, GameMatcher)
        if "/store_item_assets/steam/apps/" in low:
            parts = path.split("/apps/", 1)[1].split("/")
            if "empty-library" in self.state.armed:
                return b"not found\n", "text/plain", 404
            if len(parts) == 2 and parts[0].isdigit() and parts[1].endswith(".jpg"):
                kind = parts[1][:-4]
                if kind in ("library_600x900", "library_hero", "library_capsule"):
                    return fixtures.cover_png(int(parts[0]), kind), "image/png", 200
            return b"not found\n", "text/plain", 404

        # Valve's Steam installer (SteamSetup.valveInstaller)
        if low.endswith("/client/installer/steam.dmg"):
            return (b"QA stub steam.dmg: not mountable; the QA world plants Steam.app "
                    b"directly.\n"), "application/x-apple-diskimage", 200

        # Valve package CDN files (valve-packages.manifest bases)
        base = path.rsplit("/", 1)[-1]
        if ".zip." in base and all(c in "0123456789abcdef" for c in base.rsplit(".", 1)[-1]):
            return _valve_zip(base, "corrupt-download" in self.state.armed), "application/zip", 200

        # Compat builder sources (tools/compat; the app never calls these)
        if "getmostplayedgames" in low:
            if "empty-library" in self.state.armed:
                return b'{"response": {"ranks": []}}', "application/json", 200
            return (fixtures.DATA / "steam-most-played.json").read_bytes(), "application/json", 200
        if low.endswith("/w/api.php") or "applegamingwiki" in low:
            return _agw(query)
        if "bdefore/protondb-data/contents/reports" in low:
            return (fixtures.DATA / "protondb-listing.json").read_bytes(), "application/json", 200
        if base.startswith("reports_") and base.endswith(".tar.gz"):
            return _protondb_export(), "application/gzip", 200
        if "areweanticheatyet" in low and low.endswith("games.json"):
            return (fixtures.DATA / "awacy-games.json").read_bytes(), "application/json", 200

        # winetricks src (PrefixTools)
        if "/winetricks/" in low and low.endswith("/src"):
            return (b"#!/bin/sh\n# QA stub winetricks\necho 'winetricks stub (QA)'\n",
                    "text/plain", 200)

        # P10 stores — TO VERIFY AFTER P10 MERGES
        if low.startswith("/stores/"):
            return self._stores(path, low)

        # P14 RetroAchievements — TO VERIFY AFTER P14 MERGES
        if "dorequest.php" in low:
            return json.dumps(fixtures.ra_dorequest(
                query, hardcore="ra-hardcore" in self.state.armed)).encode(), \
                "application/json", 200

        # P14 netplay lobby — TO VERIFY AFTER P14 MERGES
        if low.rstrip("/").endswith("/lobby") or low.endswith("/lobby/list"):
            return fixtures.lobby_list("netplay-lobby" in self.state.armed), \
                "application/json", 200

        return f"mock: no route for {path}\n".encode(), "text/plain", 404

    # ---------------------------------------------------------------- stores

    def _stores(self, path, low):
        parts = [p for p in low.split("/") if p]
        if len(parts) < 2 or parts[1] not in STORES:
            return b"stores are /stores/{epic,gog,amazon}/...\n", "text/plain", 404
        store = parts[1]
        if store in self.state.expired_stores:
            return json.dumps({"error": "token expired", "store": store}).encode(), \
                "application/json", 401
        what = parts[2] if len(parts) > 2 else "status"
        if what == "games":
            if "empty-library" in self.state.armed:
                return b'{"games": []}', "application/json", 200
            return fixtures.store_games(store), "application/json", 200
        if what == "status":
            return fixtures.store_status(store, expired=False), "application/json", 200
        return b"unknown store endpoint\n", "text/plain", 404

    # ---------------------------------------------------------------- control

    def _control(self, path):
        tail = path[len("/__control"):].strip("/")
        if self.command == "GET" and tail in ("",):
            self._json({
                "scenarios": SCENARIOS,
                "parameterized": [
                    "store-token-expired:<epic|gog|amazon>",
                    "download-running:<appid>", "download-done:<appid>"],
                "actions": sorted(ACTIONS),
                "armed": sorted(self.state.armed),
                "state": "/__control/state",
                "requests": "/__control/requests",
            })
            return
        if self.command == "GET" and tail == "state":
            self._json(self.state.snapshot())
            return
        if self.command == "GET" and tail == "requests":
            self._json(self.state.snapshot() | {"requests": self.state.requests[-500:]})
            return
        if self.command == "POST" and tail == "clear":
            with self.state.lock:
                self.state.armed.clear()
                self.state.expired_stores.clear()
                self.state.downloads.clear()
            self._json({"ok": True, "cleared": True})
            return
        if self.command == "POST" and tail == "reset-fetch":
            with self.state.lock:
                self.state.fetch_resets += 1
                self.state.requests.clear()
            self._json({"ok": True, "reset": True})
            return
        if self.command == "POST" and tail:
            ok, detail = self.state.arm(urllib.parse.unquote(tail))
            self._json({"ok": ok, "detail": detail}, 200 if ok else 400)
            return
        if self.command == "DELETE" and tail:
            self.state.disarm(urllib.parse.unquote(tail))
            self._json({"ok": True})
            return
        self._send(405, b"method not allowed\n", "text/plain")


# ---------------------------------------------------------------- helpers

def _corrupt(body):
    """Same length, different bytes: a download that fails its SHA-256 check."""
    b = bytearray(body)
    if len(b) > 32:
        b[16] ^= 0xFF
        b[-16] ^= 0xFF
    else:
        b[0] ^= 0xFF
    return bytes(b)


def _valve_zip(name, corrupt):
    """A tiny zip standing in for a Valve package file (bins_*.zip.<sha1>)."""
    import zipfile
    body = io.BytesIO()
    with zipfile.ZipFile(body, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("qa-stub.txt", f"QA stub for {name}\n")
        z.writestr("legacycompat/steamclient.dll", b"MZ" + b"\x00" * 62)
    data = body.getvalue()
    return _corrupt(data) if corrupt else data


def _agw(query):
    """AppleGamingWiki w/api.php for the compat builder (replay.py shape)."""
    if query.get("generator", [""])[0] == "embeddedin":
        return (fixtures.DATA / "agw-listing.json").read_bytes(), "application/json", 200
    if "pageids" in query:
        wanted = {int(p) for p in query["pageids"][0].split("|") if p.isdigit()}
        body = json.loads((fixtures.DATA / "agw-content.json").read_text())
        body["query"]["pages"] = [p for p in body["query"]["pages"] if p["pageid"] in wanted]
        return json.dumps(body).encode(), "application/json", 200
    return b'{"error": "unknown api call"}', "application/json", 400


def _protondb_export():
    """The monthly export tar.gz the compat builder unpacks."""
    data = (fixtures.DATA / "protondb-reports.json").read_bytes()
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        info = tarfile.TarInfo("reports_piiremoved.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return out.getvalue()


# ---------------------------------------------------------------- main

def serve(port):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.state = State()
    server.daemon_threads = True
    print(f"QA control: http://127.0.0.1:{server.server_port}/__control", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8890)
    args = parser.parse_args()
    serve(args.port)


if __name__ == "__main__":
    main()
