import contextlib
import datetime
import gzip
import io
import json
import pathlib
import tempfile
import unittest

import build_compat
from compatdata import build, cache, http, replay, schema
from tests.support import FIXTURES, NIGHT, build_fixtures, quiet

EARLIER = NIGHT - datetime.timedelta(days=1)
SOURCES = ["applegamingwiki", "protondb", "areweanticheatyet"]


class SourceDownTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.previous, _ = build_fixtures(now=EARLIER)

    def test_each_source_down_keeps_its_previous_records_with_their_old_date(self):
        for down in SOURCES:
            with self.subTest(down=down):
                doc, _ = build_fixtures(previous=self.previous, down=[down])
                self.assertEqual(schema.errors(doc, schema.load()), [])
                self.assertEqual(doc["generated"], "2026-10-19T03:17:00Z")
                self.assertEqual(doc["sources"][down]["status"], "stale")
                self.assertEqual(doc["sources"][down]["fetched"], self.previous["sources"][down]["fetched"])
                for other in set(SOURCES) - {down}:
                    self.assertEqual(doc["sources"][other]["status"], "fresh")
                    self.assertEqual(doc["sources"][other]["fetched"], "2026-10-19")
                kept = {a: r[down] for a, r in doc["records"].items() if down in r}
                before = {a: r[down] for a, r in self.previous["records"].items() if down in r}
                self.assertEqual(kept, before)
                build.encode(doc)

    def test_kept_wiki_records_carry_the_old_date(self):
        doc, _ = build_fixtures(previous=self.previous, down=["applegamingwiki"])
        elden = doc["records"]["1245620"]
        self.assertEqual(elden["applegamingwiki"]["fetched"], "2026-10-18")
        self.assertEqual(elden["areweanticheatyet"]["fetched"], "2026-10-19")
        self.assertEqual(elden["applegamingwiki"]["ratings"]["crossover"], "playable")

    def test_without_a_previous_file_a_down_source_stops_the_build(self):
        with self.assertRaises(build.BuildFailed):
            build_fixtures(down=["protondb"])

    def test_steam_down_keeps_the_previous_games(self):
        doc, _ = build_fixtures(previous=self.previous, down=["steam"])
        self.assertEqual(set(doc["records"]), set(self.previous["records"]))

    def test_the_wiki_failing_after_its_listing_keeps_all_its_records(self):
        fetcher = replay.FixtureFetcher(FIXTURES)
        real = fetcher.get

        def failing(url, params=None, timeout=None):
            if (params or {}).get("prop") == "revisions":
                raise http.Unavailable("HTTP 503 after 4 attempts")
            return real(url, params, timeout)

        fetcher.get = failing
        doc = build.build(fetcher, cache.Cache(), NIGHT, previous=self.previous, log=quiet)
        self.assertEqual(doc["sources"]["applegamingwiki"]["status"], "stale")
        self.assertEqual(doc["records"]["1245620"]["applegamingwiki"]["fetched"], "2026-10-18")

    def test_the_command_still_publishes(self):
        with tempfile.TemporaryDirectory() as root:
            root = pathlib.Path(root)
            previous = root / "previous.json.gz"
            previous.write_bytes(build.encode(self.previous)[1])
            out = root / "compat.json.gz"
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                code = build_compat.main([
                    "--fixtures", str(FIXTURES), "--down", "applegamingwiki", "--previous", str(previous),
                    "--now", "2026-10-19T03:17:00Z", "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertIn("applegamingwiki: stale, 2026-10-18", printed.getvalue())
            doc = json.loads(gzip.decompress(out.read_bytes()))
            self.assertEqual(doc["sources"]["applegamingwiki"]["status"], "stale")


if __name__ == "__main__":
    unittest.main()
