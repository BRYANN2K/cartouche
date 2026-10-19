#!/usr/bin/env python3
"""Unit tests for qa/mocks/server.py — one test per route and per scenario.

    python3 -m unittest qa.mocks.test_server -v        (from the repo root)
    python3 qa/mocks/test_server.py                    (from anywhere)
"""

import gzip
import hashlib
import http.client
import io
import json
import sys
import tarfile
import threading
import time
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fixtures  # noqa: E402
import server  # noqa: E402


def _free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class MockServerCase(unittest.TestCase):
    server = None
    thread = None
    port = None

    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", cls.port), server.Handler)
        cls.httpd.state = server.State()
        cls.httpd.daemon_threads = True
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def setUp(self):
        # every test starts from a clean scenario state
        self.req("POST", "/__control/clear")

    # ------------------------------------------------------------ helpers

    def req(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        conn.request(method, path, body=body)
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response.status, data, dict(response.getheaders())

    def get(self, path):
        return self.req("GET", path)

    def post(self, path):
        return self.req("POST", path)

    def get_json(self, path):
        status, body, _ = self.get(path)
        self.assertEqual(status, 200, f"{path} -> {status}")
        return json.loads(body)


# ---------------------------------------------------------------- control

class TestControl(MockServerCase):

    def test_control_lists_every_scenario_name(self):
        doc = self.get_json("/__control")
        for name in server.SCENARIOS:
            self.assertIn(name, doc["scenarios"], name)
        for name in ("net-down", "compat-stale", "compat-corrupt", "macgamingdb-down",
                     "update-available", "update-foreign-key", "beta-available",
                     "netplay-lobby", "ra-hardcore", "ra-no-mcp", "onboarding-reset"):
            self.assertIn(name, doc["scenarios"])
        self.assertIn("store-token-expired:<epic|gog|amazon>", doc["parameterized"])
        self.assertIn("download-running:<appid>", doc["parameterized"])

    def test_arm_and_disarm(self):
        status, body, _ = self.post("/__control/net-down")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["ok"])
        self.assertIn("net-down", self.get_json("/__control/state")["armed"])
        status, _, _ = self.req("DELETE", "/__control/net-down")
        self.assertEqual(status, 200)
        self.assertNotIn("net-down", self.get_json("/__control/state")["armed"])

    def test_unknown_scenario_is_400(self):
        status, body, _ = self.post("/__control/definitely-not-a-scenario")
        self.assertEqual(status, 400)
        self.assertFalse(json.loads(body)["ok"])

    def test_parameterized_stores(self):
        for store in ("epic", "gog", "amazon"):
            status, _, _ = self.post(f"/__control/store-token-expired:{store}")
            self.assertEqual(status, 200, store)
            self.assertIn(store, self.get_json("/__control/state")["expired_stores"])
        status, _, _ = self.post("/__control/store-token-expired:origin")
        self.assertEqual(status, 400)

    def test_download_appids(self):
        self.post("/__control/download-running:1245620")
        self.assertEqual(self.get_json("/__control/state")["downloads"]["1245620"], "running")
        self.post("/__control/download-done:1245620")
        self.assertEqual(self.get_json("/__control/state")["downloads"]["1245620"], "done")
        status, _, _ = self.post("/__control/download-running:notanappid")
        self.assertEqual(status, 400)

    def test_clear_and_reset_fetch(self):
        self.post("/__control/net-down")
        self.post("/__control/clear")
        self.assertEqual(self.get_json("/__control/state")["armed"], [])
        self.get("/api/rest/games/1245620")
        self.assertGreater(len(self.get_json("/__control/requests")["requests"]), 0)
        self.post("/__control/reset-fetch")
        self.assertEqual(self.get_json("/__control/requests")["requests"], [])

    def test_request_log_records_paths(self):
        self.get("/api/rest/games/730")
        self.get("/rdb/Nintendo%20-%20Game%20Boy.rdb")
        log = self.get_json("/__control/requests")["requests"]
        paths = [r["path"] for r in log]
        self.assertIn("/api/rest/games/730", paths)
        self.assertTrue(any("Game%20Boy" in p or "Game Boy" in p for p in paths))

    def test_recorded_only_scenarios_arm(self):
        # scenarios owned by other fakes are still accepted and reported
        for name in ("steam-closed", "steam-absent", "homebrew-present",
                     "installer-good", "installer-fail-unarc", "crash-missing-dll",
                     "fps-session", "injection-blocked", "bios-missing", "bios-present",
                     "icloud-synced-state", "controller-dualsense",
                     "perm-appmgmt-denied", "perm-downloads-denied", "perm-inputmon-later",
                     "agent-pending-approval", "onboarding-reset"):
            status, _, _ = self.post(f"/__control/{name}")
            self.assertEqual(status, 200, name)


# ---------------------------------------------------------------- MacGamingDB

class TestMacGamingDB(MockServerCase):

    def test_all_fixture_games_answer(self):
        for appid in fixtures.GAME_NAMES:
            status, body, _ = self.get(f"/api/rest/games/{appid}")
            self.assertEqual(status, 200, appid)
            doc = json.loads(body)
            self.assertEqual(doc["game"]["id"], str(appid))
            self.assertIn("reviews", doc)

    def test_elden_ring_is_the_recording(self):
        doc = self.get_json("/api/rest/games/1245620")
        self.assertEqual(doc["game"]["name"], "ELDEN RING")
        self.assertGreater(len(doc["reviews"]), 10)
        for review in doc["reviews"]:
            for field in ("chipset", "playMethod", "performance", "createdAt"):
                self.assertIn(field, review)

    def test_generated_reports_have_app_shape(self):
        doc = self.get_json("/api/rest/games/1091500")
        report = doc["reviews"][0]
        self.assertRegex(report["chipset"], r"^(M[1-9]|A[1-9][0-9])")
        self.assertIn(report["playMethod"], ("NATIVE", "CROSSOVER", "PARALLELS", "OTHER"))
        self.assertIn(report["performance"],
                      ("UNPLAYABLE", "BARELY_PLAYABLE", "PLAYABLE", "GOOD",
                       "VERY_GOOD", "EXCELLENT"))

    def test_no_reports_game(self):
        doc = self.get_json(f"/api/rest/games/{fixtures.APPID_NO_REPORTS}")
        self.assertEqual(doc["game"]["reviewCount"], 0)
        self.assertEqual(doc["reviews"], [])

    def test_server_error_game(self):
        status, _, _ = self.get(f"/api/rest/games/{fixtures.APPID_SERVER_ERROR}")
        self.assertEqual(status, 500)

    def test_unknown_game_404(self):
        status, _, _ = self.get("/api/rest/games/42")
        self.assertEqual(status, 404)

    def test_macgamingdb_down_scenario(self):
        self.post("/__control/macgamingdb-down")
        status, _, _ = self.get("/api/rest/games/1245620")
        self.assertEqual(status, 503)


# ---------------------------------------------------------------- compat feed

class TestCompatFeed(MockServerCase):
    PATH = "/BRYANN2K/cartouche/releases/download/compat-data/compat.json.gz"
    RUNNERS = "/BRYANN2K/cartouche/releases/download/compat-data/runners.json"

    def _doc(self, path=PATH):
        status, body, headers = self.get(path)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "application/gzip")
        return json.loads(gzip.decompress(body))

    def test_fresh_compat_file(self):
        doc = self._doc()
        self.assertEqual(doc["schema_version"], 1)
        self.assertIn("sources", doc)
        self.assertIn("gpu_strength", doc)
        for appid in fixtures.GAME_NAMES:
            self.assertIn(str(appid), doc["records"], appid)
        for source in doc["sources"].values():
            self.assertEqual(source["status"], "fresh")

    def test_also_serves_short_path(self):
        self._doc("/compat.json.gz")

    def test_compat_stale(self):
        self.post("/__control/compat-stale")
        doc = self._doc()
        for source in doc["sources"].values():
            self.assertEqual(source["status"], "stale")

    def test_compat_corrupt(self):
        self.post("/__control/compat-corrupt")
        status, body, _ = self.get(self.PATH)
        self.assertEqual(status, 200)
        doc = json.loads(gzip.decompress(body))  # JSON, but not the schema
        self.assertNotIsInstance(doc["gpu_strength"], dict)

    def test_runners_manifest(self):
        manifest = self.get_json(self.RUNNERS)
        self.assertEqual(manifest["format"], 1)
        self.assertEqual(manifest["revision"], 2)
        ids = [b["id"] for b in manifest["builds"]]
        self.assertIn("wine-stable-11.0_1", ids)
        self.assertIn("wine-crossover-26.3.0-1", ids)
        # bundled builds keep their shipped pin, or the app rejects the manifest
        shipped = {b["id"]: b["sha256"] for b in manifest["builds"]}
        self.assertEqual(shipped["wine-stable-11.0_1"],
                         "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388")

    def test_qa_build_sha_matches_served_asset(self):
        manifest = self.get_json(self.RUNNERS)
        build = next(b for b in manifest["builds"] if b["id"] == "wine-crossover-26.3.0-1")
        status, body, _ = self.get("/" + build["url"].split("github.com/", 1)[1])
        self.assertEqual(status, 200)
        self.assertEqual(hashlib.sha256(body).hexdigest(), build["sha256"])
        self.assertEqual(len(body), build["size"])

    def test_manifest_passes_app_rules(self):
        # RunnerManifest.problems(): github.com https URLs, lowercase sha256,
        # inside paths, known flavors, wineBuild kind only
        manifest = self.get_json(self.RUNNERS)
        flavors = {"rosetta", "fex"}
        for b in manifest["builds"]:
            self.assertTrue(b["url"].startswith("https://github.com/"), b["id"])
            self.assertRegex(b["sha256"], r"^[0-9a-f]{64}$", b["id"])
            self.assertGreater(b["size"], 0)
            self.assertEqual(b["kind"], "wineBuild")
            self.assertTrue(b["id"]) 
            for path_key in ("root", "loader"):
                self.assertFalse(b[path_key].startswith("/"))
                self.assertNotIn("..", b[path_key].split("/"))
            for flavor in b["flavors"]:
                self.assertIn(flavor, flavors)
            self.assertIn(b["origin"], ("cartouche", "winehq"))

    def test_backends_manifest(self):
        doc = self.get_json("/x/releases/download/compat-data/backends.json")
        for pin in doc["backends"]:
            self.assertIn(pin["backend"], ("dxmt", "dxvk"))
            self.assertTrue(pin["url"].startswith("https://github.com/"))
            self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
            status, body, _ = self.get("/" + pin["url"].split("github.com/", 1)[1])
            self.assertEqual(status, 200)
            self.assertEqual(hashlib.sha256(body).hexdigest(), pin["sha256"])


# ---------------------------------------------------------------- appcast

class TestAppcast(MockServerCase):
    PATH = "/BRYANN2K/cartouche/releases/latest/download/appcast.xml"

    def test_default_feed_offers_no_update(self):
        _, body, _ = self.get(self.PATH)
        self.assertIn(b"<sparkle:version>0.1.0</sparkle:version>", body)
        self.assertNotIn(b"0.2.0", body)

    def test_update_available(self):
        self.post("/__control/update-available")
        _, body, _ = self.get(self.PATH)
        self.assertIn(b"Cartouche-0.2.0.zip", body)
        self.assertNotIn(b"sparkle:channel", body)

    def test_beta_available(self):
        self.post("/__control/beta-available")
        _, body, _ = self.get(self.PATH)
        self.assertIn(b"<sparkle:channel>beta</sparkle:channel>", body)
        self.assertIn(b"Cartouche-0.2.0-beta.1.zip", body)

    def test_foreign_key(self):
        self.post("/__control/update-foreign-key")
        _, body, _ = self.get(self.PATH)
        # the update item is signed with a foreign key; the current item is not
        self.assertIn(fixtures._FOREIGN_SIG.encode(), body)
        self.assertEqual(body.count(fixtures._FOREIGN_SIG.encode()), 1)
        self.assertEqual(body.count(fixtures._ED_SIG.encode()), 1)  # only the 0.1.0 item


# ---------------------------------------------------------------- assets

class TestReleaseAssets(MockServerCase):

    def test_winehq_assets(self):
        for name in ("wine-stable-11.0_1-osx64.tar.xz", "wine-devel-11.18-osx64.tar.xz"):
            status, body, _ = self.get(f"/Gcenx/macOS_Wine_builds/releases/download/x/{name}")
            self.assertEqual(status, 200, name)
            self.assertGreater(len(body), 0)

    def test_dxmt_and_dxvk_assets_unpack(self):
        for name, members in (
            ("dxmt-v0.80-builtin.tar.gz",
             ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll",
              "x86_64-windows/winemetal.dll", "x86_64-unix/winemetal.so"]),
            ("dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
             ["x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll"]),
        ):
            status, body, _ = self.get(f"/3Shain/dxmt/releases/download/v/{name}")
            self.assertEqual(status, 200, name)
            with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as tar:
                for member in members:
                    self.assertIsNotNone(tar.getmember(member), member)

    def test_app_zip(self):
        status, body, _ = self.get(
            "/BRYANN2K/cartouche/releases/download/v0.2.0/Cartouche-0.2.0.zip")
        self.assertEqual(status, 200)
        names = zipfile.ZipFile(io.BytesIO(body)).namelist()
        self.assertIn("Cartouche.app/Contents/Info.plist", names)

    def test_corrupt_download_scenario(self):
        path = "/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
        _, good, _ = self.get(path)
        self.post("/__control/corrupt-download")
        _, bad, _ = self.get(path)
        self.assertNotEqual(hashlib.sha256(good).hexdigest(),
                            hashlib.sha256(bad).hexdigest())
        self.assertEqual(len(good), len(bad))  # size pin passes, hash fails

    def test_tampered_route(self):
        status, body, _ = self.get(
            "/BRYANN2K/cartouche/releases/download/v9.9.9/wine-tampered.tar.xz")
        self.assertEqual(status, 200)
        self.assertNotEqual(body, b"QA tampered archive\n" * 16)

    def test_unknown_asset_404(self):
        status, _, _ = self.get("/some/repo/releases/download/v1/missing.tar.xz")
        self.assertEqual(status, 404)


# ---------------------------------------------------------------- libretro

class TestLibretro(MockServerCase):

    def test_core_zip_has_macho_member(self):
        status, body, _ = self.get(
            "/nightly/apple/osx/arm64/latest/snes9x_libretro.dylib.zip")
        self.assertEqual(status, 200)
        archive = zipfile.ZipFile(io.BytesIO(body))
        self.assertEqual(archive.namelist(), ["snes9x_libretro.dylib"])
        self.assertTrue(archive.read("snes9x_libretro.dylib")[:4] == b"\xcf\xfa\xed\xfe")

    def test_unknown_core_zip(self):
        status, body, _ = self.get(
            "/nightly/apple/osx/arm64/latest/stella_libretro.dylib.zip")
        # every catalog core exists; a nonsense name still zips (buildbot lists all)
        self.assertEqual(status, 200)
        status, _, _ = self.get("/nightly/apple/osx/arm64/latest/notacore.zip")
        self.assertEqual(status, 404)

    def test_info_zip(self):
        status, body, _ = self.get("/assets/frontend/info.zip")
        self.assertEqual(status, 200)
        archive = zipfile.ZipFile(io.BytesIO(body))
        self.assertIn("snes9x_libretro.info", archive.namelist())
        self.assertIn("swanstation_libretro.info", archive.namelist())
        info = archive.read("swanstation_libretro.info").decode()
        self.assertIn("scph5501.bin", info)
        self.assertIn("490f666e1afb15b7362b406ed1cea246", info)

    def test_retroarch_dmg(self):
        status, body, _ = self.get("/stable/1.22.2/apple/osx/universal/RetroArch_Metal.dmg")
        self.assertEqual(status, 200)
        self.assertIn(b"WITH-MCP", body)

    def test_ra_no_mcp(self):
        self.post("/__control/ra-no-mcp")
        _, body, _ = self.get("/stable/1.22.2/apple/osx/universal/RetroArch_Metal.dmg")
        self.assertIn(b"NO-MCP", body)

    def test_rdb_files(self):
        for system in ("Nintendo - Super Nintendo Entertainment System",
                       "Nintendo - Game Boy", "Sony - PlayStation"):
            url = "/rdb/" + system.replace(" ", "%20") + ".rdb"
            status, body, _ = self.get(url)
            self.assertEqual(status, 200, system)
            self.assertTrue(body.startswith(b"RARCHDB"), system)

    def test_rdb_parses_like_swift_writer(self):
        # read it back with the same wire rules as RetroArchKit.RDB
        status, body, _ = self.get(
            "/rdb/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System.rdb")
        self.assertEqual(status, 200)
        self.assertIn(b"Super Metroid", body)
        self.assertIn(b"Cartouche Homebrew", body)
        # trailer: 0x81 map {"count": u64 N} — 16 bytes, ending the file
        self.assertEqual(body[-16], 0x81)
        self.assertEqual(int.from_bytes(body[-8:], "big"), 5)  # 5 SNES rows

    def test_rdb_unknown_system(self):
        status, _, _ = self.get("/rdb/Atari%20-%202600.rdb")
        self.assertEqual(status, 404)

    def test_thumbnails(self):
        base = "/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System"
        name = "/Super%20Metroid%20(Japan%2C%20USA)%20(En%2CJa).png"
        for kind in ("Named_Boxarts", "Named_Titles", "Named_Snaps"):
            status, body, headers = self.get(base + "/" + kind + name)
            self.assertEqual(status, 200, kind)
            self.assertTrue(body.startswith(b"\x89PNG"), kind)
            self.assertEqual(headers.get("Content-Type"), "image/png")

    def test_thumbnail_bad_path(self):
        status, _, _ = self.get("/Named_Boxarts/")
        self.assertEqual(status, 404)


# ---------------------------------------------------------------- steam

class TestSteam(MockServerCase):

    def test_covers(self):
        for appid in fixtures.GAME_NAMES:
            status, body, _ = self.get(
                f"/store_item_assets/steam/apps/{appid}/library_600x900.jpg")
            self.assertEqual(status, 200, appid)
            self.assertTrue(body[:4] in (b"\xff\xd8\xff\xe0", b"\x89PNG") or
                            body.startswith(b"\x89PNG"))
        status, body, _ = self.get("/store_item_assets/steam/apps/1245620/library_hero.jpg")
        self.assertEqual(status, 200)
        self.assertTrue(body.startswith(b"\x89PNG"))

    def test_cover_bad_kind(self):
        status, _, _ = self.get("/store_item_assets/steam/apps/1245620/notakind.jpg")
        self.assertEqual(status, 404)

    def test_steam_dmg(self):
        status, body, _ = self.get("/client/installer/steam.dmg")
        self.assertEqual(status, 200)
        self.assertIn(b"QA stub", body)

    def test_valve_package(self):
        status, body, _ = self.get(
            "/client/bins_misc_ubuntu12.zip.3f92810725ee673827371a0470cd4f8c7ea8cfae")
        self.assertEqual(status, 200)
        self.assertTrue(zipfile.is_zipfile(io.BytesIO(body)))

    def test_charts(self):
        doc = self.get_json("/ISteamChartsService/GetMostPlayedGames/v1/")
        self.assertIn("ranks", doc["response"])
        self.assertGreater(len(doc["response"]["ranks"]), 0)


# ---------------------------------------------------------------- compat builder sources

class TestCompatSources(MockServerCase):

    def test_agw_listing(self):
        doc = self.get_json("/w/api.php?generator=embeddedin&geititle=Template:X")
        self.assertIn("pages", doc["query"])

    def test_agw_content_filters_pageids(self):
        doc = self.get_json("/w/api.php?prop=revisions&pageids=296|1795")
        ids = [p["pageid"] for p in doc["query"]["pages"]]
        self.assertEqual(sorted(ids), [296, 1795])

    def test_protondb_listing_and_export(self):
        listing = self.get_json("/repos/bdefore/protondb-data/contents/reports")
        self.assertTrue(any(e["name"].startswith("reports_") for e in listing))
        status, body, _ = self.get(
            "/bdefore/protondb-data/master/reports/reports_oct1_2026.tar.gz")
        self.assertEqual(status, 200)
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as tar:
            member = next(m for m in tar.getmembers() if m.name.endswith(".json"))
            reports = json.loads(tar.extractfile(member).read())
        self.assertIsInstance(reports, list)

    def test_awacy(self):
        doc = self.get_json("/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json")
        self.assertTrue(any(g.get("slug") == "apex-legends" for g in doc))

    def test_winetricks(self):
        status, body, _ = self.get("/Winetricks/winetricks/20260101/src")
        self.assertEqual(status, 200)
        self.assertTrue(body.startswith(b"#!"))


# ---------------------------------------------------------------- stores (P10)

class TestStores(MockServerCase):

    def test_each_store_lists_games(self):
        for store in ("epic", "gog", "amazon"):
            doc = self.get_json(f"/stores/{store}/games")
            self.assertIn("games", doc)
            self.assertGreater(len(doc["games"]), 0, store)

    def test_store_status(self):
        doc = self.get_json("/stores/epic/status")
        self.assertTrue(doc["signed_in"])

    def test_token_expired(self):
        self.post("/__control/store-token-expired:epic")
        status, body, _ = self.get("/stores/epic/games")
        self.assertEqual(status, 401)
        self.assertEqual(json.loads(body)["store"], "epic")
        # other stores unaffected
        status, _, _ = self.get("/stores/gog/games")
        self.assertEqual(status, 200)


# ---------------------------------------------------------------- P14 extras

class TestP14(MockServerCase):

    def test_ra_login(self):
        doc = self.get_json("/retroachievements/dorequest.php?r=login2&u=qa&p=x")
        self.assertTrue(doc["Success"])
        self.assertIn("Token", doc)

    def test_ra_patch_hardcore_flag(self):
        _, body, _ = self.get("/retroachievements/dorequest.php?r=patch&i=99901")
        self.assertFalse(json.loads(body)["HardcoreMode"])
        self.post("/__control/ra-hardcore")
        doc = self.get_json("/retroachievements/dorequest.php?r=patch&i=99901")
        self.assertTrue(doc["HardcoreMode"])

    def test_lobby_empty_then_friends_game(self):
        doc = self.get_json("/lobby/")
        self.assertEqual(doc["rooms"], [])
        self.post("/__control/netplay-lobby")
        doc = self.get_json("/lobby/")
        self.assertEqual(len(doc["rooms"]), 1)
        self.assertEqual(doc["rooms"][0]["username"], "QAFriend")


# ---------------------------------------------------------------- global scenarios

class TestGlobalScenarios(MockServerCase):

    def test_net_down(self):
        self.post("/__control/net-down")
        for path in ("/api/rest/games/1245620", "/compat.json.gz",
                     "/store_item_assets/steam/apps/730/library_600x900.jpg",
                     "/stores/epic/games"):
            status, _, _ = self.get(path)
            self.assertEqual(status, 503, path)
        status, _, _ = self.get("/__control")  # control still answers
        self.assertEqual(status, 200)

    def test_offline_alias(self):
        self.post("/__control/offline")
        self.assertIn("net-down", self.get_json("/__control/state")["armed"])
        status, _, _ = self.get("/api/rest/games/730")
        self.assertEqual(status, 503)

    def test_slow(self):
        self.post("/__control/slow")
        start = time.monotonic()
        status, _, _ = self.get("/api/rest/games/730")
        elapsed = time.monotonic() - start
        self.assertEqual(status, 200)
        self.assertGreaterEqual(elapsed, server.SLOW_SECONDS - 0.1)

    def test_empty_library(self):
        self.post("/__control/empty-library")
        status, _, _ = self.get("/api/rest/games/1245620")
        self.assertEqual(status, 404)
        doc = self.get_json("/stores/epic/games")
        self.assertEqual(doc["games"], [])
        doc = self.get_json("/ISteamChartsService/GetMostPlayedGames/v1/")
        self.assertEqual(doc["response"]["ranks"], [])

    def test_unknown_route_404(self):
        status, body, _ = self.get("/definitely/not/a/route")
        self.assertEqual(status, 404)
        self.assertIn(b"no route", body)


if __name__ == "__main__":
    unittest.main()
