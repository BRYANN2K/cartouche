"""diff_coverage.py against a scratch repository and hand-written lcov reports."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "diff_coverage.py"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class DiffCoverage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "ci@example.invalid")
        git(self.root, "config", "user.name", "ci")
        src = self.root / "pkg/Sources/Kit"
        src.mkdir(parents=True)
        (src / "A.swift").write_text("".join(f"let a{i} = {i}\n" for i in range(1, 11)))
        git(self.root, "add", ".")
        git(self.root, "commit", "-q", "-m", "base")
        self.base = git(self.root, "rev-parse", "HEAD")
        # The change edits lines 3 and 4 and adds 11 and 12
        lines = (src / "A.swift").read_text().splitlines()
        lines[2], lines[3] = "let a3 = 30", "let a4 = 40"
        lines += ["let a11 = 11", "let a12 = 12"]
        (src / "A.swift").write_text("\n".join(lines) + "\n")
        (self.root / "pkg/Tests").mkdir()
        (self.root / "pkg/Tests/T.swift").write_text("let t = 1\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-q", "-m", "change")
        (self.root / "baseline.json").write_text(json.dumps({"total_percent": 50.0}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_gate(self, hits, baseline=None, extra=()):
        das = "".join(f"DA:{n},{c}\n" for n, c in hits.items())
        (self.root / "a.lcov").write_text(
            f"SF:pkg/Sources/Kit/A.swift\n{das}end_of_record\nSF:pkg/Tests/T.swift\nDA:1,0\nend_of_record\n")
        if baseline is not None:
            (self.root / "baseline.json").write_text(json.dumps({"total_percent": baseline}))
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--lcov", "a.lcov", "--base", self.base, "--baseline", "baseline.json", *extra],
            cwd=self.root, capture_output=True, text=True)

    def test_changed_lines_covered_passes(self):
        r = self.run_gate({n: 1 for n in range(1, 13)})
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("changed lines: 100.00% covered (4 of 4)", r.stdout)

    def test_changed_lines_below_minimum_fails(self):
        hits = {n: 1 for n in range(1, 13)}
        hits[11] = hits[12] = 0
        r = self.run_gate(hits)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL changed lines: 50.00% covered (2 of 4)", r.stdout)
        self.assertIn("not covered: pkg/Sources/Kit/A.swift:11", r.stdout)

    def test_uninstrumented_changed_lines_are_left_out(self):
        hits = {n: 1 for n in range(1, 11)}
        r = self.run_gate(hits)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("(2 of 2)", r.stdout)

    def test_total_drop_fails(self):
        r = self.run_gate({n: 1 for n in range(1, 13)}, baseline=100.5)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL total dropped below the baseline", r.stdout)

    def test_tests_folder_is_not_counted(self):
        r = self.run_gate({n: 1 for n in range(1, 13)})
        self.assertIn("(12 of 12 lines, 1 files)", r.stdout)

    def test_missing_base_checks_the_total_only(self):
        das = "".join(f"DA:{n},1\n" for n in range(1, 13))
        (self.root / "a.lcov").write_text(f"SF:pkg/Sources/Kit/A.swift\n{das}end_of_record\n")
        r = subprocess.run(
            [sys.executable, str(SCRIPT), "--lcov", "a.lcov", "--base", "0" * 40, "--baseline", "baseline.json"],
            cwd=self.root, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("skip changed lines", r.stdout)

    def test_write_baseline(self):
        r = self.run_gate({1: 1, 2: 0}, extra=("--write-baseline",))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(json.loads((self.root / "baseline.json").read_text()), {"total_percent": 50.0})


if __name__ == "__main__":
    unittest.main()
