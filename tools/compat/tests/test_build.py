import gzip
import json
import tempfile
import unittest
from unittest import mock

from compatdata import build, cache, replay, schema
from tests.support import FIXTURES, NIGHT, build_fixtures, quiet


class FixtureBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc, cls.fetcher = build_fixtures()

    def test_file_matches_the_schema(self):
        self.assertEqual(schema.errors(self.doc, schema.load()), [])

    def test_generated_is_the_build_night(self):
        self.assertEqual(self.doc["generated"], "2026-10-19T03:17:00Z")

    def test_records_are_keyed_by_app_id(self):
        self.assertEqual(sorted(self.doc["records"], key=int), ["730", "632470", "1172470", "1245620"])

    def test_no_macgamingdb_field_or_value_is_published(self):
        raw, packed = build.encode(self.doc)
        self.assertNotIn(b"macgamingdb", raw.lower())
        self.assertNotIn(b"macgamingdb", gzip.decompress(packed).lower())
        self.assertFalse([u for u, _ in self.fetcher.requests if "macgamingdb" in u])

    def test_apex_does_not_run_on_linux_with_eac_and_hyperion(self):
        apex = self.doc["records"]["1172470"]
        self.assertEqual(apex["protondb"]["verdict"], "doesnt_run")
        self.assertEqual(apex["protondb"]["works"], 0)
        self.assertEqual(apex["areweanticheatyet"]["anticheats"], ["Easy Anti-Cheat", "Hyperion"])
        self.assertEqual(apex["areweanticheatyet"]["status"], "Denied")

    def test_wiki_ratings_are_read_per_method(self):
        self.assertEqual(self.doc["records"]["1245620"]["applegamingwiki"]["ratings"],
                         {"native": "na", "rosetta2": "na", "crossover": "playable",
                          "wine": "perfect", "parallels": "unplayable"})
        self.assertEqual(self.doc["records"]["632470"]["applegamingwiki"]["ratings"]["native"], "perfect")

    def test_protondb_counts_one_year_before_the_export(self):
        pdb = self.doc["records"]["730"]["protondb"]
        self.assertEqual((pdb["fetched"], pdb["since"]), ("2026-10-01", "2025-10-01"))
        self.assertEqual(self.doc["sources"]["protondb"]["export"], "reports_oct1_2026")

    def test_every_value_sits_under_a_named_source(self):
        for app, record in self.doc["records"].items():
            self.assertLessEqual(set(record) - {"name"}, set(self.doc["sources"]), app)
        names = {s["name"]: s["license"] for s in self.doc["sources"].values()}
        self.assertEqual(names["AppleGamingWiki"], "CC BY-NC-SA 3.0")
        self.assertEqual(names["ProtonDB"], "ODbL")
        self.assertEqual(names["AreWeAntiCheatYet"], "MIT")
        self.assertEqual([s["credit"] for s in self.doc["sources"].values()],
                         ["AppleGamingWiki (CC BY-NC-SA 3.0)", "ProtonDB (ODbL)",
                          "AreWeAntiCheatYet (MIT)"])

    def test_names_prefer_the_wiki(self):
        self.assertEqual(self.doc["records"]["1245620"]["name"], "Elden Ring")
        self.assertEqual(self.doc["records"]["1172470"]["name"], "Apex Legends")

    def test_requests_name_the_project(self):
        from compatdata import http
        self.assertIn("Cartouche", http.USER_AGENT)


class AppFixtureTests(unittest.TestCase):
    def test_the_app_tests_read_the_current_fixture_build(self):
        # The Swift tests read this file. Rebuild it with:
        # python3 tools/compat/build_compat.py --fixtures tools/compat/fixtures/2026-10-19 \
        #   --now 2026-10-19T03:17:00Z --out tools/compat/fixtures/compat-2026-10-19.json.gz
        committed = FIXTURES.parent / "compat-2026-10-19.json.gz"
        doc, _ = build_fixtures()
        self.assertEqual(json.loads(gzip.decompress(committed.read_bytes())), doc)

class CacheTests(unittest.TestCase):
    def test_a_second_night_fetches_only_listings(self):
        with tempfile.TemporaryDirectory() as root:
            first, fetcher = build_fixtures(store=cache.Cache(root))
            second_store = cache.Cache(root)
            second, fetcher = build_fixtures(store=second_store, previous=first)
            asked = [url for url, params in fetcher.requests]
            self.assertFalse([u for u in asked if "/api/rest/games/" in u and "sitemap" not in u])
            self.assertFalse([p for u, p in fetcher.requests if p.get("prop") == "revisions"])
            self.assertFalse([u for u in asked if u.endswith(".tar.gz")])
            self.assertEqual(second_store.misses, 0)
            self.assertEqual(second["records"], first["records"])

    def test_unused_entries_are_pruned(self):
        with tempfile.TemporaryDirectory() as root:
            store = cache.Cache(root)
            store.put("applegamingwiki/1/old", {"x": 1})
            build_fixtures(store=store)
            fresh = cache.Cache(root)
            build_fixtures(store=fresh)
            self.assertEqual(fresh.prune(), 1)


class FailureTests(unittest.TestCase):
    def test_unknown_format_stops_the_build(self):
        fetcher = replay.FixtureFetcher(FIXTURES)
        real = fetcher.get

        def broken(url, params=None, timeout=None):
            if url.endswith("games.json"):
                return json.dumps({"games": []}).encode()
            return real(url, params, timeout)

        fetcher.get = broken
        with self.assertRaises(build.BuildFailed) as caught:
            build.build(fetcher, cache.Cache(), NIGHT, log=quiet)
        self.assertIn("areweanticheatyet", str(caught.exception))

    def test_a_file_over_the_limit_is_refused(self):
        doc, _ = build_fixtures()
        with mock.patch.object(build, "MAX_BYTES", 100):
            with self.assertRaises(build.BuildFailed):
                build.encode(doc)

    def test_encoded_file_is_gzip_of_the_document(self):
        doc, _ = build_fixtures()
        raw, packed = build.encode(doc)
        self.assertLess(len(packed), 25 * 1000 * 1000)
        self.assertEqual(json.loads(gzip.decompress(packed)), doc)
        self.assertEqual(build.encode(doc)[1], packed, "two encodings of one document differ")

    def test_a_schema_break_stops_the_build(self):
        with mock.patch.object(build, "GPU_STRENGTH") as path:
            path.read_text.return_value = '{"Radeon": 1}'
            with self.assertRaises(build.BuildFailed) as caught:
                build_fixtures()
        self.assertIn("schema", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
