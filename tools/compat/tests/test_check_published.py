import contextlib
import gzip
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import check_published
from compatdata import build
from tests.support import build_fixtures


class CheckPublishedTests(unittest.TestCase):
    def run_check(self, packed, *args):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "compat.json.gz"
            path.write_bytes(packed)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                return check_published.main([str(path), *args])

    def setUp(self):
        self.doc, _ = build_fixtures()
        self.packed = build.encode(self.doc)[1]

    def test_fixture_build_passes_on_its_night(self):
        self.assertEqual(self.run_check(self.packed, "--night", "2026-10-19"), 0)

    def test_another_night_fails(self):
        self.assertEqual(self.run_check(self.packed, "--night", "2026-10-20"), 1)

    def test_an_invalid_file_fails(self):
        self.doc["records"]["730"]["protondb"]["verdict"] = "borked"
        packed = gzip.compress(json.dumps(self.doc).encode())
        self.assertEqual(self.run_check(packed), 1)

    def test_a_file_carrying_macgamingdb_fails(self):
        for change in (lambda d: d["records"]["730"].update(macgamingdb={}),
                       lambda d: d["records"]["730"].update(name="Seen on MacGamingDB")):
            doc = json.loads(json.dumps(self.doc))
            change(doc)
            self.assertEqual(self.run_check(gzip.compress(json.dumps(doc).encode())), 1)

    def test_a_file_over_the_limit_fails(self):
        with mock.patch.object(build, "MAX_BYTES", 100):
            self.assertEqual(self.run_check(self.packed), 1)


if __name__ == "__main__":
    unittest.main()
