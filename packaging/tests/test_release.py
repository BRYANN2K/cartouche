"""Unit tests for packaging/release.py."""
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "packaging"))
import release  # noqa: E402

S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
CHANGELOG = textwrap.dedent("""\
    # Changelog

    ## [Unreleased]

    - Nothing yet.

    ## [0.2.0] - 2026-11-20 (critical)

    - Fixes the dylib after the Steam update of 2026-11-19.

    ## [0.2.0-beta.1] - 2026-11-10

    - Beta of the console library.

    ## [0.1.0] - 2026-11-01

    - First release.

    ## [0.0.9]
""")


class Tmp(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.changelog = self.tmp / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG)

    def tearDown(self):
        self._tmp.cleanup()

    def header(self, version):
        h = self.tmp / "version.h"
        h.write_text(f'#define CARTOUCHE_VERSION "{version}"\n')
        return h


class Tags(Tmp):
    def test_kinds(self):
        self.assertEqual(release.parse_tag("v0.1.0"), ("0.1.0", "release"))
        self.assertEqual(release.parse_tag("v0.2.0-beta.3"), ("0.2.0-beta.3", "beta"))
        self.assertEqual(release.parse_tag("v0.0.1-test.1"), ("0.0.1-test.1", "test"))

    def test_bad_tags_are_refused(self):
        for tag in ("0.1.0", "v0.1", "v0.1.0-rc.1", "v0.1.0-beta", "v0.1.0 ", "vX.Y.Z"):
            with self.assertRaises(release.ReleaseError, msg=tag):
                release.parse_tag(tag)

    def test_bundle_versions(self):
        self.assertEqual(release.bundle_version("0.1.0"), "0.1.0")
        self.assertEqual(release.bundle_version("0.2.0-beta.12"), "0.2.0b12")
        self.assertEqual(release.bundle_version("0.0.1-test.2"), "0.0.1t2")

    def test_release_meta(self):
        m = release.meta("v0.1.0", self.header("0.1.0"), self.changelog, [])
        self.assertEqual((m["version"], m["channel"], m["prerelease"], m["critical"], m["bump_tap"]),
                         ("0.1.0", "", "false", "false", "true"))
        self.assertEqual(m["archive"], "Cartouche-0.1.0.zip")

    def test_beta_meta(self):
        m = release.meta("v0.2.0-beta.1", self.header("0.2.0-beta.1"), self.changelog, ["v0.1.0"])
        self.assertEqual((m["channel"], m["prerelease"], m["bump_tap"], m["bundle_version"]),
                         ("beta", "true", "false", "0.2.0b1"))

    def test_critical_comes_from_the_changelog_heading(self):
        self.assertEqual(release.meta("v0.2.0", self.header("0.2.0"), self.changelog, [])["critical"], "true")

    def test_tag_must_match_the_built_version(self):
        with self.assertRaisesRegex(release.ReleaseError, "bump CARTOUCHE_VERSION"):
            release.meta("v0.1.0", self.header("1.2.0"), self.changelog, [])

    def test_order_matches_the_app(self):
        ordered = (ROOT / "packaging/tests/version-order.txt").read_text().split()
        self.assertGreater(len(ordered), 5)
        self.assertEqual(sorted(reversed(ordered), key=release.version_key), ordered)
        for older, newer in (("0.1.0", "0.2.0-beta.1"), ("0.2.0-beta.1", "0.2.0-beta.2"),
                             ("0.2.0-beta.2", "0.2.0"), ("0.0.1-test.1", "0.0.1-test.2")):
            self.assertLess(release.version_key(older), release.version_key(newer))

    def test_a_release_must_be_newer_than_the_last_one(self):
        self.changelog.write_text(CHANGELOG + "\n## [0.1.1]\n\n- Fix.\n")
        release.meta("v0.2.0", self.header("0.2.0"), self.changelog, ["v0.1.0", "v0.2.0-beta.1"])
        with self.assertRaisesRegex(release.ReleaseError, "not newer than the published release 0.2.0"):
            release.meta("v0.1.1", self.header("0.1.1"), self.changelog, ["v0.1.0", "v0.2.0"])
        with self.assertRaisesRegex(release.ReleaseError, "not newer"):
            release.meta("v0.2.0-beta.1", self.header("0.2.0-beta.1"), self.changelog, ["v0.2.0"])
        # A beta of the next version may follow a beta already out
        release.meta("v0.2.0-beta.1", self.header("0.2.0-beta.1"), self.changelog, ["v0.1.0", "v0.2.0-beta.0"])

    def test_test_tags_stop_after_the_first_release(self):
        self.changelog.write_text(CHANGELOG + "\n## [0.0.1-test.1]\n\n- Pipeline test.\n")
        release.meta("v0.0.1-test.1", self.header("0.0.1-test.1"), self.changelog, ["v0.0.1-test.0"])
        with self.assertRaisesRegex(release.ReleaseError, "before the first release"):
            release.meta("v0.0.1-test.1", self.header("0.0.1-test.1"), self.changelog, ["v0.1.0"])


class Notes(Tmp):
    def test_section_body(self):
        body, rest = release.changelog_section(self.changelog, "0.1.0")
        self.assertEqual(body, "- First release.")
        self.assertEqual(rest, " - 2026-11-01")

    def test_beta_section_is_not_confused_with_the_release(self):
        self.assertEqual(release.changelog_section(self.changelog, "0.2.0-beta.1")[0], "- Beta of the console library.")
        self.assertIn("Steam update", release.changelog_section(self.changelog, "0.2.0")[0])

    def test_missing_or_empty_section_fails(self):
        with self.assertRaisesRegex(release.ReleaseError, "no '## \\[0.3.0\\]'"):
            release.changelog_section(self.changelog, "0.3.0")
        with self.assertRaisesRegex(release.ReleaseError, "empty"):
            release.changelog_section(self.changelog, "0.0.9")

    def test_repository_changelog_has_an_unreleased_section(self):
        text = (ROOT / "CHANGELOG.md").read_text()
        self.assertIn("## [Unreleased]", text)


class Checksums(Tmp):
    def verify(self):
        return subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=self.tmp, capture_output=True,
                              text=True)

    def test_checksum_verifies_and_catches_a_tampered_zip(self):
        archive = self.tmp / "Cartouche-0.1.0.zip"
        archive.write_bytes(b"PK\x03\x04" + bytes(range(256)) * 64)
        (self.tmp / "SHA256SUMS").write_text(release.checksums([archive]))
        line = (self.tmp / "SHA256SUMS").read_text()
        self.assertRegex(line, r"^[0-9a-f]{64}  Cartouche-0\.1\.0\.zip\n$")
        self.assertEqual(self.verify().returncode, 0)

        data = bytearray(archive.read_bytes())
        data[100] ^= 1
        archive.write_bytes(bytes(data))
        r = self.verify()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("FAILED", r.stdout)

    def test_matches_hashlib(self):
        archive = self.tmp / "a.zip"
        archive.write_bytes(b"cartouche")
        self.assertEqual(release.sha256(archive), hashlib.sha256(b"cartouche").hexdigest())


class Cask(Tmp):
    DIGEST = "a" * 64

    def render(self, version="0.1.0"):
        return release.cask(ROOT / "packaging/homebrew/cartouche.rb.in", version, self.DIGEST)

    def test_fills_version_and_checksum(self):
        text = self.render()
        self.assertIn('version "0.1.0"', text)
        self.assertIn(f'sha256 "{self.DIGEST}"', text)
        self.assertNotIn("@", text.replace("users.noreply", ""))

    def test_url_is_the_release_archive(self):
        # Ruby interpolates #{version}; the result must be what release.yml uploads
        text = self.render()
        url = re.search(r'url "([^"]+)"', text).group(1).replace("#{version}", "0.1.0")
        self.assertEqual(url, "https://github.com/BRYANN2K/NotProton/releases/download/v0.1.0/"
                         + release.ARCHIVE.format(version="0.1.0"))
        self.assertNotIn("NotProtonNot", text)

    def test_cask_is_valid_ruby(self):
        ruby = shutil.which("ruby")
        if not ruby:
            self.skipTest("ruby not found")
        path = self.tmp / "cartouche.rb"
        path.write_text(self.render())
        r = subprocess.run([ruby, "-c", path], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_bad_checksum_is_refused(self):
        with self.assertRaises(release.ReleaseError):
            release.cask(ROOT / "packaging/homebrew/cartouche.rb.in", "0.1.0", "abc")


def feed(items):
    xml = ['<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
           'version="2.0"><channel><title>Cartouche</title>']
    for version, url, sig, deltas in items:
        d = "".join(f'<enclosure url="{u}" sparkle:deltaFrom="x" sparkle:edSignature="{s}"/>' for u, s in deltas)
        xml.append(f'<item><title>{version}</title><sparkle:version>{version}</sparkle:version>'
                   f'<enclosure url="{url}" sparkle:edSignature="{sig}"/>'
                   + (f"<sparkle:deltas>{d}</sparkle:deltas>" if d else "") + "</item>")
    xml.append("</channel></rss>")
    return "".join(xml)


class Merge(Tmp):
    P = "https://example.test/download/v0.2.0/"

    def write(self, name, items):
        path = self.tmp / name
        path.write_text(feed(items))
        return path

    def test_keeps_old_items_and_takes_the_new_one(self):
        prev = self.write("prev.xml", [("0.1.0", "https://example.test/download/v0.1.0/Cartouche-0.1.0.zip", "a", [])])
        gen = self.write("gen.xml", [
            ("0.2.0", self.P + "Cartouche-0.2.0.zip", "b", [(self.P + "Cartouche0.2.0-0.1.0.delta", "c")]),
            ("0.1.0", self.P + "Cartouche-0.1.0.zip", "a2", [])])
        root, deltas = release.merge_appcast(prev, gen, "0.2.0", "Cartouche-0.2.0.zip", self.P)
        urls = [i.find("enclosure").get("url") for i in root.iter("item")]
        self.assertEqual(urls, [self.P + "Cartouche-0.2.0.zip",
                                "https://example.test/download/v0.1.0/Cartouche-0.1.0.zip"])
        self.assertEqual(deltas, ["Cartouche0.2.0-0.1.0.delta"])

    def test_first_release_has_no_previous_feed(self):
        gen = self.write("gen.xml", [("0.1.0", "https://example.test/download/v0.1.0/Cartouche-0.1.0.zip", "a", [])])
        root, deltas = release.merge_appcast(None, gen, "0.1.0", "Cartouche-0.1.0.zip",
                                             "https://example.test/download/v0.1.0/")
        self.assertEqual(len(list(root.iter("item"))), 1)
        self.assertEqual(deltas, [])

    def test_unsigned_archive_is_refused(self):
        gen = self.write("gen.xml", [("0.2.0", self.P + "Cartouche-0.2.0.zip", "", [])])
        with self.assertRaisesRegex(release.ReleaseError, "no EdDSA signature"):
            release.merge_appcast(None, gen, "0.2.0", "Cartouche-0.2.0.zip", self.P)

    def test_unsigned_delta_is_refused(self):
        gen = self.write("gen.xml", [("0.2.0", self.P + "Cartouche-0.2.0.zip", "b", [(self.P + "d.delta", "")])])
        with self.assertRaisesRegex(release.ReleaseError, "delta .* no EdDSA"):
            release.merge_appcast(None, gen, "0.2.0", "Cartouche-0.2.0.zip", self.P)

    def test_wrong_download_url_is_refused(self):
        gen = self.write("gen.xml", [("0.2.0", "https://example.test/elsewhere/Cartouche-0.2.0.zip", "b", [])])
        with self.assertRaisesRegex(release.ReleaseError, "expected"):
            release.merge_appcast(None, gen, "0.2.0", "Cartouche-0.2.0.zip", self.P)

    def test_republishing_a_version_replaces_its_item(self):
        prev = self.write("prev.xml", [("0.2.0", self.P + "Cartouche-0.2.0.zip", "old", [])])
        gen = self.write("gen.xml", [("0.2.0", self.P + "Cartouche-0.2.0.zip", "new", [])])
        root, _ = release.merge_appcast(prev, gen, "0.2.0", "Cartouche-0.2.0.zip", self.P)
        sigs = [i.find("enclosure").get(S + "edSignature") for i in root.iter("item")]
        self.assertEqual(sigs, ["new"])

    def test_test_items_are_dropped_by_a_real_version(self):
        prev = self.write("prev.xml", [("0.0.1t2", "u2", "a", []), ("0.0.1t1", "u1", "a", [])])
        gen = self.write("gen.xml", [("0.1.0", self.P + "Cartouche-0.1.0.zip", "b", [])])
        root, _ = release.merge_appcast(prev, gen, "0.1.0", "Cartouche-0.1.0.zip", self.P)
        self.assertEqual([i.findtext(S + "version") for i in root.iter("item")], ["0.1.0"])
        gen = self.write("gen.xml", [("0.0.1t3", self.P + "Cartouche-0.0.1-test.3.zip", "b", [])])
        root, _ = release.merge_appcast(prev, gen, "0.0.1t3", "Cartouche-0.0.1-test.3.zip", self.P)
        self.assertEqual(len(list(root.iter("item"))), 3)

    def test_previous_archives_are_the_newest_items(self):
        prev = self.write("prev.xml", [(v, f"https://x/{v}.zip", "s", []) for v in ("4", "3", "2", "1")])
        self.assertEqual(release.previous_archives(prev, 3),
                         [("4", "https://x/4.zip"), ("3", "https://x/3.zip"), ("2", "https://x/2.zip")])

    def test_written_feed_parses(self):
        gen = self.write("gen.xml", [("0.1.0", "https://example.test/download/v0.1.0/Cartouche-0.1.0.zip", "a", [])])
        root, _ = release.merge_appcast(None, gen, "0.1.0", "Cartouche-0.1.0.zip",
                                        "https://example.test/download/v0.1.0/")
        out = self.tmp / "appcast.xml"
        release.write_tree(root, out)
        self.assertIn("xmlns:sparkle=", out.read_text())
        ET.parse(out)


if __name__ == "__main__":
    unittest.main()
