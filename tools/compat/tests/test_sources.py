import datetime
import json
import unittest

from compatdata import cache
from compatdata.sources import applegamingwiki, protondb


PAGE = """{{Infobox game
|cover        = X.jpg
|steam appid  = 1245620, 2778580
|steam appid side = 1173140
}}

{{Compatibility/macOS
|native               = na
|native notes         = Uses {{Refdevice|user=A|device=M1|method=Wine}} and [[Link|a link]].
|rosetta 2            = <!-- not tested --> unknown
|crossover            = Playable
|crossover notes      = line one
line two with | inside <ref>{{Refcheck|user=B|date=2025-01-01}}</ref>
|wine                 = superb
|parallels            =
|linux arm            = menu
}}
"""


class AppleGamingWikiTests(unittest.TestCase):
    def test_template_splits_at_its_own_pipes(self):
        values = applegamingwiki.template(PAGE, "Compatibility/macOS")
        self.assertEqual(values["native"], "na")
        self.assertIn("{{Refdevice|user=A|device=M1|method=Wine}}", values["native notes"])
        self.assertNotIn("method", values)

    def test_page_is_parsed(self):
        warnings = []
        page = applegamingwiki.parse_page(PAGE, warnings, "Elden Ring")
        self.assertEqual(page["appids"], ["1245620", "2778580"])
        self.assertEqual(page["ratings"], {"native": "na", "rosetta2": "unknown", "crossover": "playable",
                                           "wine": "unknown", "parallels": "unknown"})
        self.assertEqual(len(warnings), 1, warnings)

    def test_menu_is_a_rating(self):
        page = applegamingwiki.parse_page("{{Compatibility/macOS|crossover = menu}}", [], "X")
        self.assertEqual(page["ratings"]["crossover"], "menu")

    def test_an_app_id_on_two_pages_goes_to_the_newer_edit(self):
        pages = [{"pageid": 1, "title": "Old Game", "lastrevid": 900},
                 {"pageid": 2, "title": "Old Game Remastered", "lastrevid": 1200}]
        text = "{{Infobox game|steam appid = 730}}{{Compatibility/macOS|wine = %s}}"

        class Wiki:
            def get(self, url, params=None, timeout=None):
                if params.get("generator"):
                    return json.dumps({"query": {"pages": pages}}).encode()
                return json.dumps({"query": {"pages": [
                    {"pageid": p["pageid"], "title": p["title"],
                     "revisions": [{"revid": p["lastrevid"], "slots": {"main": {
                         "content": text % ("perfect" if p["pageid"] == 2 else "unplayable")}}}]}
                    for p in pages]}}).encode()

        result = applegamingwiki.fetch(Wiki(), cache.Cache(), "2026-10-19")
        self.assertEqual(result.blocks["730"]["page"], "Old Game Remastered")
        self.assertEqual(result.blocks["730"]["ratings"]["wine"], "perfect")

    def test_page_without_template_has_no_ids(self):
        self.assertEqual(applegamingwiki.parse_page("{{Infobox game|steam appid = 1}}", [], "X"),
                         {"appids": []})


class ProtonDBTests(unittest.TestCase):
    def test_export_names(self):
        self.assertEqual(protondb.export_date("reports_oct1_2026.tar.gz"), datetime.date(2026, 10, 1))
        self.assertEqual(protondb.export_date("reports_sep30_2019.tar.gz"), datetime.date(2019, 9, 30))
        self.assertIsNone(protondb.export_date("README.md"))
        self.assertIsNone(protondb.export_date("reports_foo1_2026.tar.gz"))

    def test_verdict_thresholds(self):
        self.assertEqual(protondb.verdict(4, 3), "runs")
        self.assertEqual(protondb.verdict(4, 2), "mixed")
        self.assertEqual(protondb.verdict(4, 1), "doesnt_run")
        self.assertEqual(protondb.verdict(149, 0), "doesnt_run")

    def test_summary_counts_the_last_year_only(self):
        day = datetime.date(2026, 10, 1)
        ts = lambda y, m, d: datetime.datetime(y, m, d, tzinfo=datetime.timezone.utc).timestamp()
        report = lambda t, verdict, online=None, played=None: {
            "app": {"steam": {"appId": "730"}, "title": "CS2"}, "timestamp": t,
            "responses": {"verdict": verdict, **({"onlineMultiplayerAttempted": online} if online else {}),
                          **({"onlineMultiplayerPlayed": played} if played else {})}}
        summary = protondb.summarize([
            report(ts(2025, 9, 30), "no"),
            report(ts(2025, 10, 1), "yes", "yes", "yes"),
            report(ts(2026, 5, 1), "yes", "yes", "no"),
            report(ts(2026, 6, 1), "no"),
            report(ts(2026, 6, 2), "maybe"),
        ], day)
        self.assertEqual(summary["since"], "2025-10-01")
        self.assertEqual(summary["games"]["730"], {"reports": 3, "works": 2, "online_tried": 2,
                                                   "online_played": 1, "title": "CS2", "verdict": "mixed"})


if __name__ == "__main__":
    unittest.main()
