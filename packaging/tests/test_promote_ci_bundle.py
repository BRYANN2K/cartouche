import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1] / "promote-ci-bundle.py"
spec = importlib.util.spec_from_file_location("promote_ci_bundle", MODULE)
promote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promote)


class ProvenanceTests(unittest.TestCase):
    def test_only_the_successful_exact_commit_with_matching_bytes_is_accepted(self):
        with tempfile.TemporaryDirectory() as work:
            folder = pathlib.Path(work)
            archive = folder / "Cartouche.zip"
            archive.write_bytes(b"CI artifact")
            metadata = {"head_sha": "a" * 40, "conclusion": "success",
                        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
            provenance = folder / "provenance.json"
            provenance.write_text(json.dumps(metadata))
            self.assertEqual(promote.verified_archive(folder, "a" * 40), archive)
            with self.assertRaises(ValueError):
                promote.verified_archive(folder, "b" * 40)
            provenance.write_text(json.dumps(metadata | {"conclusion": "failure"}))
            with self.assertRaises(ValueError):
                promote.verified_archive(folder, "a" * 40)
            provenance.write_text(json.dumps(metadata))
            archive.write_bytes(b"changed after download")
            with self.assertRaises(ValueError):
                promote.verified_archive(folder, "a" * 40)


if __name__ == "__main__":
    unittest.main()
