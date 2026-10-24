"""End to end: four releases through make-appcast.sh with Sparkle's real tools,
fake app bundles and a throwaway EdDSA key, the way release.yml chains them."""
import base64
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = pathlib.Path(os.environ.get("SPARKLE_BIN", ROOT / "app/.build/artifacts/sparkle/Sparkle/bin"))
MAKE_APPCAST = ROOT / "packaging/make-appcast.sh"
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
REPO_URL = "https://github.com/BRYANN2K/cartouche/releases/download"

sys.path.insert(0, str(ROOT / "packaging"))
from release import bundle_version  # noqa: E402


def openssl():
    # Ed25519 needs OpenSSL 3; macOS's LibreSSL may not have it
    for c in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "openssl"):
        path = shutil.which(c)
        if path and b"OpenSSL 3" in subprocess.run([path, "version"], capture_output=True).stdout:
            return path
    return None


def keypair(work):
    ossl = openssl()
    pem = work / "ed.pem"
    subprocess.run([ossl, "genpkey", "-algorithm", "ed25519", "-out", pem], check=True)
    der = subprocess.run([ossl, "pkey", "-in", pem, "-outform", "DER"], check=True, capture_output=True).stdout
    pub = subprocess.run([ossl, "pkey", "-in", pem, "-pubout", "-outform", "DER"], check=True,
                         capture_output=True).stdout
    return base64.b64encode(der[-32:]).decode(), base64.b64encode(pub[-32:]).decode()


def make_app(work, version, public_key):
    app = work / "apps" / version / "Cartouche.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources").mkdir()
    src = work / f"main-{version}.c"
    src.write_text(f'int main(void){{ return {len(version)}; }} const char *v = "{version}";\n')
    subprocess.run(["clang", "-o", app / "Contents/MacOS/Cartouche", src], check=True)
    (app / "Contents/Resources/data.bin").write_bytes(os.urandom(4096) + version.encode() * 200)
    (app / "Contents/Info.plist").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cartouche</string>
<key>CFBundleIdentifier</key><string>dev.bryann2k.cartouche</string>
<key>CFBundleName</key><string>Cartouche</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
<key>CFBundleVersion</key><string>{bundle_version(version)}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>SUPublicEDKey</key><string>{public_key}</string>
</dict></plist>
""")
    subprocess.run(["codesign", "-fs", "-", app], check=True, capture_output=True)
    store = work / "published"
    store.mkdir(exist_ok=True)
    zip_path = store / f"Cartouche-{version}.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", app, zip_path], check=True)
    return zip_path


@unittest.skipUnless((BIN / "generate_appcast").exists(), "Sparkle tools not resolved (swift package resolve)")
@unittest.skipUnless(shutil.which("codesign") and shutil.which("clang"), "needs macOS")
@unittest.skipIf(openssl() is None, "needs OpenSSL 3 for an Ed25519 test key")
class AppcastChain(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.work = pathlib.Path(tempfile.mkdtemp())
        cls.private, cls.public = keypair(cls.work)
        cls.feeds = {}
        published = None
        # A pipeline test, the first release, a beta, then a critical release
        for version, channel, critical in (("0.0.9-test.1", "", False), ("0.1.0", "", False),
                                           ("0.2.0-beta.1", "beta", False), ("0.2.0", "", True)):
            zip_path = make_app(cls.work, version, cls.public)
            rel = cls.work / "release" / version
            rel.mkdir(parents=True)
            shutil.copy(zip_path, rel)
            (rel / f"Cartouche-{version}.html").write_text(f"<p>Notes for {version}</p>")
            if published:
                shutil.copy(published, rel / "previous-appcast.xml")
                # release.yml downloads these URLs; here they map to the local store
                listed = subprocess.run(["python3", ROOT / "packaging/release.py", "previous-archives", published],
                                        check=True, capture_output=True, text=True).stdout.split("\n")
                for line in filter(None, listed):
                    url = line.split()[1]
                    shutil.copy(cls.work / "published" / url.rsplit("/", 1)[1], rel)
            env = dict(os.environ, SPARKLE_PRIVATE_KEY=cls.private, SPARKLE_BIN=str(BIN))
            subprocess.run(["sh", MAKE_APPCAST, rel, version, f"{REPO_URL}/v{version}/", channel,
                            "true" if critical else "false"], check=True, env=env, capture_output=True)
            published = rel / "appcast.xml"
            cls.feeds[version] = published

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work)

    def items(self, version):
        # Keyed by the version users see; sparkle:version is the bundle version
        return {i.find(S + "shortVersionString").text: i
                for i in ET.parse(self.feeds[version]).getroot().iter("item")}

    def test_old_items_keep_their_own_release_url(self):
        final = self.items("0.2.0")
        self.assertEqual(final["0.1.0"].find("enclosure").get("url"), f"{REPO_URL}/v0.1.0/Cartouche-0.1.0.zip")
        self.assertEqual(final["0.2.0-beta.1"].find("enclosure").get("url"),
                         f"{REPO_URL}/v0.2.0-beta.1/Cartouche-0.2.0-beta.1.zip")
        self.assertEqual(final["0.2.0"].find("enclosure").get("url"), f"{REPO_URL}/v0.2.0/Cartouche-0.2.0.zip")
        self.assertEqual(list(final), ["0.2.0", "0.2.0-beta.1", "0.1.0"])

    def test_every_archive_and_delta_is_signed(self):
        for item in self.items("0.2.0").values():
            for enc in [item.find("enclosure")] + item.findall(f"{S}deltas/enclosure"):
                self.assertTrue(enc.get(S + "edSignature"), enc.get("url"))

    def test_new_release_has_deltas_and_ships_them(self):
        new = self.items("0.2.0")["0.2.0"]
        froms = sorted(d.get(S + "deltaFrom") for d in new.findall(f"{S}deltas/enclosure"))
        self.assertEqual(froms, ["0.1.0", "0.2.0b1"])
        rel = self.feeds["0.2.0"].parent
        listed = (rel / "deltas.txt").read_text().split()
        self.assertEqual(len(listed), 2)
        for name in listed:
            self.assertTrue((rel / name).is_file(), name)
            self.assertIn(f"{REPO_URL}/v0.2.0/{name}", [d.get("url") for d in new.findall(f"{S}deltas/enclosure")])

    def test_beta_is_on_the_beta_channel_only(self):
        final = self.items("0.2.0")
        self.assertEqual(final["0.2.0-beta.1"].findtext(S + "channel"), "beta")
        self.assertIsNone(final["0.1.0"].find(S + "channel"))
        self.assertIsNone(final["0.2.0"].find(S + "channel"))

    def test_bundle_versions_order_for_sparkle(self):
        final = self.items("0.2.0")
        self.assertEqual([final[v].findtext(S + "version") for v in final], ["0.2.0", "0.2.0b1", "0.1.0"])

    def test_critical_flag(self):
        final = self.items("0.2.0")
        self.assertIsNotNone(final["0.2.0"].find(S + "criticalUpdate"))
        self.assertIsNone(final["0.1.0"].find(S + "criticalUpdate"))

    def test_release_notes_are_embedded(self):
        self.assertIn("Notes for 0.2.0", self.items("0.2.0")["0.2.0"].findtext("description"))
        self.assertIn("Notes for 0.1.0", self.items("0.2.0")["0.1.0"].findtext("description"))

    def test_test_items_leave_with_the_first_release(self):
        self.assertIn("0.0.9-test.1", self.items("0.0.9-test.1"))
        self.assertNotIn("0.0.9-test.1", self.items("0.1.0"))

    def test_feed_signature_verifies_and_catches_tampering(self):
        env = dict(os.environ, SPARKLE_PRIVATE_KEY=self.private)
        verify = [BIN / "sign_update", "--verify", "--ed-key-file", "-"]
        ok = subprocess.run(verify + [self.feeds["0.2.0"]], input=self.private, text=True, capture_output=True,
                            env=env)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        tampered = self.work / "tampered.xml"
        tampered.write_text(self.feeds["0.2.0"].read_text().replace("Cartouche-0.1.0.zip", "Evil-0.1.0.zip"))
        bad = subprocess.run(verify + [tampered], input=self.private, text=True, capture_output=True, env=env)
        self.assertNotEqual(bad.returncode, 0)


if __name__ == "__main__":
    unittest.main()
