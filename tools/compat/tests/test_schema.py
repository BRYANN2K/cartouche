import copy
import unittest

from compatdata import schema


def sample():
    source = {
        "name": "X", "credit": "X (MIT)", "url": "https://example.org", "license": "MIT",
        "license_url": "https://example.org/license", "attribution": "Data from X.",
        "fetched": "2026-10-19", "status": "fresh",
    }
    return {
        "schema_version": 1,
        "generated": "2026-10-19T03:17:00Z",
        "sources": {name: dict(source) for name in
                    ("applegamingwiki", "protondb", "areweanticheatyet")},
        "gpu_strength": {"M1": 1, "M4": 1.9, "M4 Pro": 3.5},
        "records": {
            "1245620": {
                "name": "ELDEN RING",
                "applegamingwiki": {
                    "fetched": "2026-10-19", "page": "Elden Ring", "revision": 10743,
                    "ratings": {"native": "na", "rosetta2": "na", "crossover": "playable",
                                "wine": "perfect", "parallels": "unplayable"},
                },
                "protondb": {"fetched": "2026-10-01", "since": "2025-10-01", "reports": 205,
                             "works": 197, "online_tried": 9, "online_played": 9, "verdict": "runs"},
                "areweanticheatyet": {"fetched": "2026-10-19", "status": "Supported",
                                      "anticheats": ["Easy Anti-Cheat"], "native": False,
                                      "changed": "2024-09-08"},
            }
        },
    }


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.schema = schema.load()

    def test_sample_is_valid(self):
        self.assertEqual(schema.errors(sample(), self.schema), [])

    def broken(self, change):
        doc = sample()
        change(doc)
        return schema.errors(doc, self.schema)

    def test_each_break_is_caught(self):
        record = lambda d: d["records"]["1245620"]
        cases = {
            "missing generated": lambda d: d.pop("generated"),
            "generated is a date": lambda d: d.update(generated="2026-10-19"),
            "wrong version": lambda d: d.update(schema_version=2),
            "true is not 1": lambda d: d.update(schema_version=True),
            "unknown top key": lambda d: d.update(extra=1),
            "source missing": lambda d: d["sources"].pop("protondb"),
            "bad status": lambda d: d["sources"]["protondb"].update(status="down"),
            "plain http url": lambda d: d["sources"]["protondb"].update(url="http://x"),
            "app id with letters": lambda d: d["records"].update(abc=record(d)),
            "app id with leading zero": lambda d: d["records"].update({"0123": record(d)}),
            "record with only a name": lambda d: d["records"].update({"1": {"name": "A"}}),
            "a MacGamingDB source": lambda d: d["sources"].update(macgamingdb=d["sources"]["protondb"]),
            "a MacGamingDB block": lambda d: record(d).update(macgamingdb={"fetched": "2026-10-19"}),
            "count as text": lambda d: record(d)["protondb"].update(works="5"),
            "negative count": lambda d: record(d)["protondb"].update(online_tried=-1),
            "chip without space": lambda d: d["gpu_strength"].update({"M4Pro": 3}),
            "bad date": lambda d: record(d)["protondb"].update(since="2025-13-01"),
            "missing revision": lambda d: record(d)["applegamingwiki"].pop("revision"),
            "unknown agw rating": lambda d: record(d)["applegamingwiki"]["ratings"].update(wine="great"),
            "agw method missing": lambda d: record(d)["applegamingwiki"]["ratings"].pop("wine"),
            "protondb zero reports": lambda d: record(d)["protondb"].update(reports=0),
            "protondb verdict": lambda d: record(d)["protondb"].update(verdict="borked"),
            "awacy status": lambda d: record(d)["areweanticheatyet"].update(status="Works"),
            "awacy no anticheat": lambda d: record(d)["areweanticheatyet"].update(anticheats=[]),
            "gpu strength zero": lambda d: d["gpu_strength"].update(M2=0),
            "gpu chip name": lambda d: d["gpu_strength"].update(Radeon=1),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.assertNotEqual(self.broken(change), [], name)

    def test_a_record_needs_one_source_only(self):
        doc = sample()
        for key in ("applegamingwiki", "areweanticheatyet"):
            doc["records"]["1245620"].pop(key)
        self.assertEqual(schema.errors(doc, self.schema), [])

    def test_unknown_keyword_is_refused(self):
        bad = copy.deepcopy(self.schema)
        bad["properties"]["generated"]["maxLength"] = 30
        with self.assertRaises(schema.SchemaError):
            schema._check_keywords(bad)

    def test_unknown_format_is_refused(self):
        with self.assertRaises(schema.SchemaError):
            schema._check_keywords({"type": "string", "format": "email"})


if __name__ == "__main__":
    unittest.main()
