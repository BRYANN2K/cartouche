"""Tests for packaging/runner_manifest.py, the check before runners.json is published."""
import copy
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "packaging"))
import runner_manifest  # noqa: E402

SHIPPED = ROOT / "app" / "Sources" / "NotProtonApp" / "Resources" / "runners.json"


class RunnerManifest(unittest.TestCase):

    def setUp(self):
        self.doc = json.loads(SHIPPED.read_text())

    def test_the_shipped_manifest_is_valid(self):
        self.assertEqual(runner_manifest.problems(self.doc), [])

    def test_bad_builds_are_named(self):
        for key, value in [("sha256", "AB" * 32), ("url", "https://example.com/x.tar.xz"),
                           ("kind", "portingToolkit"), ("root", "../x"), ("size", 0), ("flavors", ["x"])]:
            doc = copy.deepcopy(self.doc)
            doc["builds"][0][key] = value
            found = runner_manifest.problems(doc)
            self.assertEqual(len(found), 1, (key, found))
            self.assertIn(doc["builds"][0]["id"], found[0])

    def test_a_publish_must_raise_the_revision_and_keep_pins(self):
        newer = copy.deepcopy(self.doc)
        newer["revision"] += 1
        self.assertEqual(runner_manifest.problems(newer, self.doc), [])
        self.assertEqual(len(runner_manifest.problems(self.doc, self.doc)), 1)
        newer["builds"][0]["sha256"] = "0" * 64
        self.assertIn("changes its published pin", runner_manifest.problems(newer, self.doc)[0])


if __name__ == "__main__":
    unittest.main()
