import copy
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "packaging"))

import store_clients  # noqa: E402

PINS = ROOT / "app/Sources/NotProtonApp/Resources/store-clients.json"


def shipped():
    return json.loads(PINS.read_text())


# What GitHub's API answered for the pinned releases, recorded on 2026-10-19
def recorded(doc):
    releases, repos = {}, {}
    for p in doc["clients"]:
        repo, tag, name = store_clients.release_of(p)
        releases[f"repos/{repo}/releases/tags/{tag}"] = {
            "assets": [{"name": name, "size": p["size"], "digest": "sha256:" + p["sha256"]}]}
        repos[f"repos/{repo}"] = {"license": {"spdx_id": p["license"]}}
    return lambda path: releases.get(path) or repos[path]


class StoreClientPins(unittest.TestCase):

    def test_shipped_pins_are_valid(self):
        self.assertEqual(store_clients.problems(shipped()), [])

    def test_every_client_is_pinned_once(self):
        names = sorted(p["client"] for p in shipped()["clients"])
        self.assertEqual(names, ["comet", "gogdl", "legendary", "nile"])

    def test_licenses_are_the_repositories(self):
        licenses = {p["client"]: p["license"] for p in shipped()["clients"]}
        self.assertEqual(licenses, {"legendary": "GPL-3.0", "gogdl": "GPL-3.0", "nile": "GPL-3.0", "comet": "Apache-2.0"})

    def test_only_apple_silicon_builds(self):
        for p in shipped()["clients"]:
            name = p["url"].rsplit("/", 1)[1].lower()
            self.assertTrue("arm64" in name or "aarch64" in name, name)

    def test_refuses_another_host_a_bad_hash_and_a_closed_license(self):
        doc = shipped()
        bad = copy.deepcopy(doc)
        bad["clients"][0]["url"] = "http://example.com/legendary"
        bad["clients"][1]["sha256"] = "ABC"
        bad["clients"][2]["license"] = "Proprietary"
        bad["clients"].append(copy.deepcopy(doc["clients"][3]))
        found = store_clients.problems(bad)
        self.assertTrue(any("not an https URL on github.com" in f for f in found))
        self.assertTrue(any("is not a SHA-256" in f for f in found))
        self.assertTrue(any("license Proprietary" in f for f in found))
        self.assertTrue(any("listed twice" in f for f in found))

    def test_a_missing_client_is_named(self):
        doc = shipped()
        doc["clients"] = [p for p in doc["clients"] if p["client"] != "comet"]
        self.assertIn("comet is not pinned", store_clients.problems(doc))

    def test_matching_release_passes_the_remote_check(self):
        doc = shipped()
        self.assertEqual(store_clients.remote_problems(doc, fetch=recorded(doc)), [])

    def test_a_replaced_asset_fails_the_remote_check(self):
        doc = shipped()
        fetch = recorded(doc)
        changed = copy.deepcopy(doc)
        changed["clients"][0]["sha256"] = "0" * 64
        changed["clients"][1]["size"] += 1
        found = store_clients.remote_problems(changed, fetch=fetch)
        self.assertEqual(len(found), 2)
        self.assertIn("GitHub has sha256:", found[0])
        self.assertIn("bytes, the pin", found[1])


if __name__ == "__main__":
    unittest.main()
